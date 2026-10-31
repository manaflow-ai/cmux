public import AppKit
import CmuxNextDesign

/// The two views of the docked Home: the sidebar's Home entry (`messages`) and its Channels entry
/// (`channels`), selected with `home.switchView` (hq-6d cx-frn2y).
public enum HomeDockMode: String, CaseIterable, Sendable {
    case messages, channels

    public var other: HomeDockMode { self == .messages ? .channels : .messages }

    /// Whether the view may show: Messages always; Channels while `home.channelsEnabled` is on (the
    /// palette's Enable Channels; Lawrence 2026-10-15).
    @MainActor public var isEnabled: Bool { self == .messages || DesignSettings.shared.homeChannelsEnabled }

    /// Refusals of `home.switchView` and of the page's `cmux.host.home.switchView`.
    public static var invalidViewMessage: String {
        String(localized: "homeDock.switch.invalidView", defaultValue: "Home has two views: messages and channels.", bundle: .module)
    }

    public static var channelsOffMessage: String {
        String(localized: "homeDock.switch.channelsOff", defaultValue: "Channels is off. Turn it on with Enable Channels in the command palette.",
               bundle: .module)
    }

    public static var classicMessage: String {
        String(localized: "homeDock.switch.classic", defaultValue: "Classic Home has only the Messages view.", bundle: .module)
    }
}

/// The selection a switch carries over (the permalink's parts).
public struct HomeDockSelection: Equatable, Sendable {
    public var conversation: String
    public var message: String?

    public init(conversation: String, message: String? = nil) {
        self.conversation = conversation
        self.message = message
    }

    /// The page route of the selection (hq-ec's hash contract, COORD.md).
    public var route: String { "/conversation/\(conversation)" + (message.map { "/message/\($0)" } ?? "") }

    /// A conversation or message id from a page or a caller: only the permalink grammar's characters
    /// (letters, digits, `_`, `-`; at most 128), so it can only ever name an id in a route.
    public nonisolated static func isLinkID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && id.allSatisfy(\.isASCII)
    }
}

/// The docked Home's tab content (cx-ebm.59.5, cx-frn2y; Lawrence 2026-10-15: "toggle between
/// messages/channels should be via cmd shift p (in fact should just be 2 diff things in section like
/// Home and Channels ..."). One of two views of the same Home data fills it, with no header: the
/// sidebar's Home entry shows Messages (the native MessagesLab list and transcript), its Channels
/// entry shows hq-ec's `home-channels` page. The app's subclass makes the two views and answers
/// their selection; this view owns which view shows and the order of switches. Each view is made on
/// its first show and kept, so a switch back keeps its scroll, draft and selection. A switch hands
/// the selection over as a permalink.
open class HomeDockSwitchView: NSView {
    private let content = NSView()
    public private(set) var mode: HomeDockMode
    /// The selection the last switch handed over (debug and GUI proofs).
    public private(set) var lastHandoff: HomeDockSelection?
    /// Told the view each time one shows (the sidebar marks its entry).
    public var onShow: (@MainActor (HomeDockMode) -> Void)?
    /// Work that lives as long as this view (the Channels setting watch); cancelled by `close()`.
    public var tasks: [Task<Void, Never>] = []
    private var made: [HomeDockMode: NSView] = [:]
    /// A switch in flight: a second one waits for it, so two quick selections end on the last one.
    private var switching: Task<Void, Never>?
    /// Work that needs this view in a window (a sheet, the keyboard).
    private var windowWaiters: [@MainActor () -> Void] = []
    /// Makes a view's tools for its pane's tab row, nil for none: the Chief's over Messages
    /// (`ChiefPaneTools`, set when the app binds its actions). Each dock view asks once, when made.
    public static var makeRowTools: (@MainActor (HomeDockMode) -> NSView?)?
    /// Tools a view puts in its pane's tab row (HomeDockSwitchView+TabRow).
    public var rowTools: [HomeDockMode: NSView] = [:] {
        didSet {
            for (_, tools) in oldValue where !rowTools.values.contains(where: { $0 === tools }) { tools.removeFromSuperview() }
            needsLayout = true
        }
    }
    /// The row the pane last offered (`setTabRow`).
    var tabRow = (height: CGFloat(0), trailingInset: CGFloat(0))
    /// The shown view's tools' width last reported to the pane, gap included; 0: none.
    var reportedToolsWidth: CGFloat = 0
    public internal(set) var tabRowToolsNeed: CGFloat?
    public var onTabRowToolsChange: (() -> Void)?

    public init(mode: HomeDockMode) {
        self.mode = mode
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.homeDock")
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        for mode in HomeDockMode.allCases { rowTools[mode] = Self.makeRowTools?(mode) }
        show(mode)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // MARK: The two views (the app's subclass)

    /// Makes `mode`'s view; called once per mode, on its first show.
    open func makeContent(for mode: HomeDockMode) -> NSView? { nil }

    /// `mode`'s selection, nil when it has none.
    open func selection(in mode: HomeDockMode) async -> HomeDockSelection? { nil }

    /// Shows `selection` in `mode`'s view.
    open func open(_ selection: HomeDockSelection, in mode: HomeDockMode) {}

    /// `mode`'s primary input takes the keyboard.
    open func focusContent(_ mode: HomeDockMode) {}

    /// The tab closed: a switch in flight and this view's tasks stop.
    open func close() {
        switching?.cancel()
        for task in tasks { task.cancel() }
        tasks = []
    }

    // MARK: Switching

    /// Runs `body` now when this view is in a window, else when it moves into one.
    public func whenInWindow(_ body: @escaping @MainActor () -> Void) {
        if window != nil { body() } else { windowWaiters.append(body) }
    }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !windowWaiters.isEmpty else { return }
        let waiters = windowWaiters
        windowWaiters = []
        for body in waiters { body() }
    }

    override open func layout() {
        super.layout()
        // Under the tab row while the shown view's tools are in it (the pane lays this view under the strip then).
        let cover = layoutRowTools()
        content.frame = NSRect(x: 0, y: isFlipped ? cover : 0, width: bounds.width, height: max(0, bounds.height - cover))
    }

    /// Switches to `target` (the other view when nil) with `selection`, else the current selection
    /// handed over. Two quick switches run in order, so the last one wins. A view that may not show
    /// (`HomeDockMode.isEnabled`: Channels while it is off) is not switched to; callers refuse first.
    /// Either way, a switch that opens a selection hands the keyboard to the shown view's primary input.
    public func switchTo(_ target: HomeDockMode?, selection given: HomeDockSelection? = nil) {
        let previous = switching
        // task-owner: one switch; a page answer is bounded by the subclass's selection deadline.
        switching = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let target = target ?? mode.other
            guard target.isEnabled else { return }
            guard target != mode else {
                // A conversation opened in the view already shown: its message box takes the
                // keyboard, as after a switch (Lawrence 2026-10-20).
                if let given {
                    open(given)
                    focusPrimaryInput()
                }
                return
            }
            var selection = given
            if selection == nil { selection = await currentSelection() }
            lastHandoff = selection
            show(target)
            if let selection { open(selection) }
            focusPrimaryInput()
        }
    }

    /// Waits for the switch in flight, if any (debug and tests).
    public func settled() async { await switching?.value }

    /// The shown view's selection.
    public func currentSelection() async -> HomeDockSelection? { await selection(in: mode) }

    /// Shows `selection` in the current view.
    public func open(_ selection: HomeDockSelection) { open(selection, in: mode) }

    /// The shown view's primary input takes the keyboard (the message box, or the page).
    public func focusPrimaryInput() { focusContent(mode) }

    private func show(_ target: HomeDockMode) {
        mode = target
        needsLayout = true // the shown view's row tools (HomeDockSwitchView+TabRow)
        let view = made[target] ?? makeContent(for: target)
        made[target] = view
        for subview in content.subviews where subview !== view { subview.isHidden = true }
        if let view {
            view.isHidden = false
            if view.superview !== content {
                view.frame = content.bounds
                view.autoresizingMask = [.width, .height]
                content.addSubview(view)
            }
        }
        onShow?(target)
    }
}
