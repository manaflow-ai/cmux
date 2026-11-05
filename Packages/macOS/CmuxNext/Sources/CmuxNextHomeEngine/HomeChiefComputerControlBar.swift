public import AppKit
import CmuxNextDesign

/// Under the Chief's screen in the profile's Computer tab and on its expanded page: who drives the
/// computer, and the one button that changes it (Chief computer take-over). "<name> is using the
/// computer" with Take Over while the Chief drives; "You're in control" (or the Chief's own reason,
/// when it asked the person to take over) with Give Back to <name> while the person does. Hidden
/// until the owner says who holds the lease, and with no source.
@MainActor
public final class HomeChiefComputerControlBar: NSStackView {
    /// What the bar shows for a lease.
    public nonisolated struct Line: Equatable, Sendable {
        public nonisolated enum Action: Equatable, Sendable { case takeOver, giveBack }
        public var status: String
        public var action: Action
    }

    /// The line for `state` (nil: not known yet, no line). A request from the Chief puts its reason
    /// in place of "You're in control", since that is what the person took over for.
    public static func line(_ state: HomeChiefComputerControlState?, chief: String) -> Line? {
        guard let state else { return nil }
        switch state.holder {
        case .chief:
            return Line(status: HomeEngineStrings.computerChiefDriving(chief), action: .takeOver)
        case .human:
            let reason = state.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Line(status: reason.isEmpty ? HomeEngineStrings.computerYouDrive : reason, action: .giveBack)
        }
    }

    let status = ThemedLabel(wrappingLabelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    /// The Chief's name, for the status and Give Back to <name>.
    var chief: () -> String = { "" }
    /// The lease's owner; nil hides the bar. Setting it starts following the lease.
    var source: HomeChiefComputerControlSource? {
        didSet { follow() }
    }
    /// The lease changed (the screen takes input only while the person holds it).
    var onChange: () -> Void = {}
    /// The line on show; nil while hidden (tests).
    private(set) var shown: Line?
    /// Why the last Take Over or Give Back did not go through; cleared by the next lease change.
    private var failed = false
    /// A Take Over or Give Back on its way.
    private var busy: Task<Void, Never>?
    private var token: AnyObject?

    public init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Metrics.space3
        setAccessibilityIdentifier("cmux.home.chief.computer.control")
        status.font = Typography.system(size: TypeScale.detail, weight: TypeScale.regular)
        status.ink = .secondary
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setAccessibilityIdentifier("cmux.home.chief.computer.control.status")
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Typography.system(size: TypeScale.detail, weight: TypeScale.regular)
        button.target = self
        button.action = #selector(clicked)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier("cmux.home.chief.computer.control.button")
        addArrangedSubview(status)
        addArrangedSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Who holds the lease now, as the source last said.
    var state: HomeChiefComputerControlState? { source?.state() }
    /// The person holds the lease.
    var personDrives: Bool { state?.holder == .human }

    private func follow() {
        token = nil
        busy?.cancel()
        busy = nil
        failed = false
        token = source?.observe { [weak self] in
            self?.failed = false
            self?.redraw()
            self?.onChange()
        }
        redraw()
        onChange()
    }

    /// Shows the source's lease (a new name too).
    func redraw() {
        let line = source == nil ? nil : Self.line(state, chief: chief())
        shown = line
        isHidden = line == nil
        guard let line else { return }
        status.stringValue = failed ? HomeEngineStrings.computerControlFailed(chief()) : line.status
        status.ink = failed ? .danger : .secondary
        button.title = line.action == .takeOver ? HomeEngineStrings.computerTakeOver : HomeEngineStrings.computerGiveBack(chief())
        button.isEnabled = busy == nil
    }

    /// Take Over (a Cloud machine's desktop opens to drive it) or Give Back. The lease's own change
    /// redraws the bar; a refusal says so until the next change.
    @discardableResult
    func act() -> Task<Void, Never>? {
        guard let source, let line = shown, busy == nil else { return nil }
        let take = line.action == .takeOver
        // task-owner: one Take Over or Give Back gesture; the button stays off until it ends
        let task = Task { [weak self] in
            do {
                if take { try await source.takeOver() } else { try await source.handBack() }
                if take { source.openInteractive?() }
                self?.failed = false
            } catch {
                self?.failed = !Task.isCancelled
            }
            guard let self, !Task.isCancelled else { return }
            busy = nil
            redraw()
            onChange()
        }
        busy = task
        redraw()
        return task
    }

    /// An input the person sent did not reach the computer: the bar says so until the next change.
    func sendFailed() {
        failed = true
        redraw()
    }

    @objc private func clicked() { act() }
}
