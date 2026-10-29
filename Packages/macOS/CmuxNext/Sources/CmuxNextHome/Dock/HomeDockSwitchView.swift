public import AppKit
public import CmuxNextCompat
import CmuxNextDesign
public import Observation

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

/// What a docked Home view showed when the sidebar section planner let it go (feature
/// `memoryDiscardSidebarSections`): the next show makes the view again from it, as Chrome builds a
/// discarded tab again from its navigation entry (content/public/browser/navigation_entry.h).
public struct HomeDockRecord: Equatable, Sendable {
    /// The conversation (and message) the view showed.
    public var selection: HomeDockSelection?
    /// The view's own place: Messages' list scroll and search (`scroll`, `query`).
    public var view: SidebarSectionState
    /// The page's route (Channels: a conversation, a sheet or a Chief's page), which a selection alone does not name.
    public var route: String?

    public init(selection: HomeDockSelection? = nil, view: SidebarSectionState = SidebarSectionState(), route: String? = nil) {
        self.selection = selection
        self.view = view
        self.route = route
    }
}

/// The docked Home's tab content (cx-ebm.59.5, cx-frn2y; Lawrence 2026-10-15: "toggle between
/// messages/channels should be via cmd shift p (in fact should just be 2 diff things in section like
/// Home and Channels ..."). One of two views of the same Home data fills it, with no header: the
/// sidebar's Home entry shows Messages (the native MessagesLab list and transcript), its Channels
/// entry shows hq-ec's `home-channels` page. The app's subclass makes the two views and answers
/// their selection; this view owns which view shows and the order of switches. Each view is made on
/// its first show and kept, so a switch back keeps its scroll, draft and selection. With the app's
/// sidebar section planner (feature `memoryDiscardSidebarSections`) the hidden view
/// goes when the planner says, its ``HomeDockRecord`` kept, and its next show makes it again from that record.
/// A switch hands the selection over as a permalink.
open class HomeDockSwitchView: NSView {
    private let content = NSView()
    /// The view shown. Observed (the view is not a model, so by hand): a reader of the shown view's selection
    /// hears a switch.
    public private(set) var mode: HomeDockMode {
        get {
            observation.access(self, keyPath: \.mode)
            return shownMode
        }
        set { observation.withMutation(of: self, keyPath: \.mode) { shownMode = newValue } }
    }
    private var shownMode: HomeDockMode
    private let observation = ObservationRegistrar()
    /// The selection the last switch handed over (debug and GUI proofs).
    public private(set) var lastHandoff: HomeDockSelection?
    /// Told the view each time one shows (the sidebar marks its entry).
    public var onShow: (@MainActor (HomeDockMode) -> Void)?
    /// Work that lives as long as this view (the Channels setting watch); cancelled by `close()`.
    public var tasks: [Task<Void, Never>] = []
    private var made: [HomeDockMode: NSView] = [:]
    /// The app's sidebar section planner; nil keeps both views for good.
    private let planner: (any SidebarSectionPlanner)?
    /// The two views on the planner's discard, with the record each released one showed.
    private lazy var releases = SidebarSectionReleases<HomeDockMode, HomeDockRecord>(owner: "homeDock", planner: planner) { [weak self] mode in
        await self?.saveViewState(in: mode)
    } drop: { [weak self] mode in
        self?.letGo(mode)
    } holdsUnsavedInput: { [weak self] mode in
        self?.holdsUnsavedInput(in: mode) ?? false
    }
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
            if rowTools.count != oldValue.count || rowTools.contains(where: { oldValue[$0.key] !== $0.value }) { needsLayout = true }
        }
    }
    /// The row the pane last offered (`setTabRow`).
    var tabRow = (height: CGFloat(0), trailingInset: CGFloat(0))
    /// The shown view's tools' width last reported to the pane, gap included; 0: none.
    var reportedToolsWidth: CGFloat = 0
    public internal(set) var tabRowToolsNeed: CGFloat?
    public var onTabRowToolsChange: (() -> Void)?

    /// - Parameters:
    ///   - mode: The view shown first.
    ///   - planner: The app's sidebar section planner, which lets the hidden view go; nil keeps both for good.
    public init(mode: HomeDockMode, planner: (any SidebarSectionPlanner)? = nil) {
        shownMode = mode
        self.planner = planner
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

    /// Makes `mode`'s view; called on its first show, and again on the first show after the planner let it go.
    open func makeContent(for mode: HomeDockMode) -> NSView? { nil }

    /// The planner let hidden `mode`'s view go (it is out of this view already): the subclass drops its references
    /// to it and ends what it runs.
    open func releaseContent(for mode: HomeDockMode) {}

    /// `mode`'s selection, nil when it has none.
    open func selection(in mode: HomeDockMode) async -> HomeDockSelection? { nil }

    /// What hidden `mode`'s view shows, saved before the planner lets it go; nil keeps nothing. Default: its selection.
    open func saveViewState(in mode: HomeDockMode) async -> HomeDockRecord? {
        await selection(in: mode).map { HomeDockRecord(selection: $0) }
    }

    /// `mode`'s view, made again after the planner let it go, shows `record`. Default: its selection.
    open func restoreViewState(_ record: HomeDockRecord, in mode: HomeDockMode) {
        if let selection = record.selection { open(selection, in: mode) }
    }

    /// `mode`'s view holds input its record does not keep (an unsent New Message, text typed in the page): the
    /// planner keeps it at any pressure.
    open func holdsUnsavedInput(in mode: HomeDockMode) -> Bool { false }

    /// Shows `selection` in `mode`'s view.
    open func open(_ selection: HomeDockSelection, in mode: HomeDockMode) {}

    /// `mode`'s primary input takes the keyboard.
    open func focusContent(_ mode: HomeDockMode) {}

    /// The tab closed: a switch in flight and this view's tasks stop.
    open func close() {
        switching?.cancel()
        releases.cancel()
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
        // main-hop-allow: the person's switch runs in order behind the one before it; `selection(in:)` is the shown view's main-actor async page answer, and the switch shows in its resume
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

    /// Shows `target` on a view made again after a discard: no selection handed over, and the
    /// keyboard stays where it is (showing a tab again is not the person choosing a view).
    public func restore(_ target: HomeDockMode) {
        guard target.isEnabled, target != mode else { return }
        show(target)
    }

    private func show(_ target: HomeDockMode) {
        mode = target
        needsLayout = true // invalidate: another view shows, and its row tools with it (HomeDockSwitchView+TabRow)
        let isNew = made[target] == nil
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
            if isNew, let record = releases.takeRecord(target) { restoreViewState(record, in: target) }
        }
        releases.show(target, hiding: made.keys, isNew: isNew && view != nil)
        onShow?(target)
    }

    /// The planner's release of hidden `mode`: its view goes, its record stays.
    private func letGo(_ mode: HomeDockMode) {
        guard mode != shownMode, let view = made.removeValue(forKey: mode) else { return }
        view.removeFromSuperview()
        releaseContent(for: mode)
    }

    /// `mode`'s view while it is made (tests and diagnostics).
    public func madeContent(_ mode: HomeDockMode) -> NSView? { made[mode] }
}

extension HomeDockSwitchView: Observable {}
