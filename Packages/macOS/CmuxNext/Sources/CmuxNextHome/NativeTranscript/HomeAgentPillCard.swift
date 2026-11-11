import AppKit
import CmuxNextDesign

/// The small card a click on an agent's pill shows when the agent has no workspace to open yet (user
/// 2026-11-08: a queued agent's pill must never do nothing): its title, where it stands ("Starts next", "1 ahead
/// of it", "Working") and, for a queued agent, Start now. A popup of the shared native host on the shared glass,
/// beside the pill; it closes on a click outside, Escape, or Start now. Home never splits.
@MainActor
final class HomeAgentPillCard {
    static let width: CGFloat = 240

    /// The agent's id (`a12`).
    let peer: String
    /// Its task's title.
    let title: String
    /// Where it stands, one line.
    let status: String
    /// Start now; nil when the agent is not queued or the host cannot start it.
    let startNowButton: ThemedBezelButton?
    /// The card's words and button, inside the glass.
    let content = NSStackView()
    private let start: (() -> Void)?
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.home.agentPillCard"))
    private let card: OverlaySurfaceView
    /// The button's target (it runs ``startNow()``); the card keeps it.
    private var action: HomeAgentPillAction?

    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - title: Its task's title.
    ///   - status: Where it stands.
    ///   - start: Start now's action; nil draws no button.
    init(peer: String, title: String, status: String, start: (() -> Void)?) {
        self.peer = peer
        self.title = title
        self.status = status
        self.start = start
        let name = NSTextField(labelWithString: title)
        name.font = Typography.bodyEmphasized
        name.lineBreakMode = .byTruncatingTail
        let line = NSTextField(labelWithString: status)
        line.font = Typography.caption
        line.textColor = .secondaryLabelColor
        var rows: [NSView] = [name, line]
        if start != nil {
            let button = ThemedDefaultButton(title: HomeAgentPillStrings.startNow, target: nil, action: #selector(HomeAgentPillAction.run))
            button.controlSize = .small
            button.keyHint = .return
            button.themedToolTip = HomeAgentPillStrings.startNowHelp
            startNowButton = button
            rows.append(button)
        } else {
            startNowButton = nil
        }
        content.setViews(rows, in: .top)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.space2
        content.setCustomSpacing(Metrics.space3, after: line)
        content.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        content.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        name.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 2 * Metrics.space3).isActive = true
        content.setAccessibilityIdentifier("cmux.home.agentPillCard")
        card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        let action = HomeAgentPillAction { [weak self] in self?.startNow() }
        startNowButton?.target = action
        self.action = action
    }

    /// True while the card shows.
    var isShown: Bool { popup.isShown }

    /// Shows the card beside `pill` (its frame in `view`), the pill's own view in a visible window.
    func show(beside pill: NSRect, of view: NSView) {
        guard let window = view.window else { return }
        popup.panel.adoptThemeScope(of: view)
        card.applyTheme()
        let anchor = window.convertToScreen(view.convert(pill, to: nil))
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: Self.width, height: ceil(content.fittingSize.height))
        popup.show(size: size, anchor: anchor, in: window, preferred: .below, makeKey: true)
    }

    func close() { popup.closePanel() }

    /// Start now was pressed: it says Starting and takes no second press until ``startFailed()``.
    private func startNow() {
        guard let startNowButton, startNowButton.isEnabled else { return }
        startNowButton.title = HomeAgentPillStrings.starting
        startNowButton.isEnabled = false
        start?()
    }

    /// The Chief did not start it: the button is back.
    func startFailed() {
        startNowButton?.title = HomeAgentPillStrings.startNow
        startNowButton?.isEnabled = true
    }
}
