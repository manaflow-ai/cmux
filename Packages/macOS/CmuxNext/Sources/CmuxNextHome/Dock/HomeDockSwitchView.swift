public import AppKit

/// The two views of the docked Home (`home.switchView`).
public enum HomeDockMode: String, CaseIterable, Sendable {
    case messages, channels

    public var other: HomeDockMode { self == .messages ? .channels : .messages }
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

/// The docked Home's tab content (cx-ebm.59.5; Lawrence 2026-10-14: "bring imessage chief back by
/// default instead of slack", "easy way to open slack ... we want to iterate on both UIs at the same
/// time"). One native header with the "Messages | Channels" switch at its top left, over one of two
/// views of the same Home data. The app's subclass makes the two views (Messages, the native
/// MessagesLab list and transcript; Channels, hq-ec's `home-channels` page) and answers their
/// selection; this view owns the header, the switch, the order of switches and which view shows.
/// Each view is made on its first show and kept, so a switch back keeps its scroll, draft and
/// selection. The switch hands the selection over as a permalink.
open class HomeDockSwitchView: NSView {
    public let header = NSView()
    public let control: HomeDockSwitchControl
    private let content = NSView()
    public private(set) var mode: HomeDockMode
    private var made: [HomeDockMode: NSView] = [:]
    /// A switch in flight: a second one waits for it, so two quick clicks end on the last choice.
    private var switching: Task<Void, Never>?
    /// Work that needs this view in a window (a sheet, the keyboard).
    private var windowWaiters: [@MainActor () -> Void] = []
    public static let headerHeight: CGFloat = 30

    public init(mode: HomeDockMode) {
        self.mode = mode
        control = HomeDockSwitchControl(labels: [HomeStrings.dockMessages, HomeStrings.dockChannels], trackingMode: .selectOne,
                                        target: nil, action: nil)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.homeDock")
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.toolTip = HomeStrings.dockSwitchHelp
        control.setAccessibilityIdentifier("cmux.homeDock.switch")
        control.target = self
        control.action = #selector(controlChanged)
        header.addSubview(control)
        addSubview(header)
        addSubview(content)
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

    /// The tab closed: a switch in flight stops.
    open func close() { switching?.cancel() }

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
        let height = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        control.sizeToFit()
        // Top left, centered in the header's height.
        control.setFrameOrigin(NSPoint(x: 8, y: ((height - control.frame.height) / 2).rounded()))
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
    }

    @objc private func controlChanged() {
        // Not compared with `mode`: a switch in flight has not changed it yet, and the last click wins.
        let index = control.selectedSegment
        guard HomeDockMode.allCases.indices.contains(index) else { return }
        switchTo(HomeDockMode.allCases[index])
    }

    /// Switches to `target` (the other view when nil) with `selection`, else the current selection
    /// handed over. Two quick switches run in order, so the last one wins.
    public func switchTo(_ target: HomeDockMode?, selection given: HomeDockSelection? = nil) {
        let previous = switching
        // task-owner: one switch; a page answer is bounded by the subclass's selection deadline.
        switching = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let target = target ?? mode.other
            guard target != mode else {
                if let given { open(given) }
                return syncControl()
            }
            var selection = given
            if selection == nil { selection = await currentSelection() }
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
        syncControl()
    }

    private func syncControl() {
        control.selectedSegment = HomeDockMode.allCases.firstIndex(of: mode) ?? 0
    }
}

/// The header switch: a click on it works in a window that is not key (no first click lost to
/// window activation), like a toolbar control.
public final class HomeDockSwitchControl: NSSegmentedControl {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
