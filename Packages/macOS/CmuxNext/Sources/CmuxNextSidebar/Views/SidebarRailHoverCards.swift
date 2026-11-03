public import AppKit
public import CmuxNextDesign

/// The rail's hover cards (`sidebar.style` = rail, plans/cmux-next/minimal-sidebar.md): pointing
/// at a mark shows one small card for that workspace (its name, an unread or working dot, its
/// Cmd-digit), anchored to the mark's row. It is a source of the app's one `HoverCardCoordinator`,
/// as the sidebar list's rows are, with the list's one anchor rule: the mark's row as a band
/// across the sidebar column (`HoverCardEscapeGeometry.rowBand`, `sidebarColumnOnScreen`), placement
/// `.besideRow`, so the card's top is the row's top and it touches the rail. Rows
/// of a group touch, and the gaps between groups bridge, so moving from mark to mark retargets
/// the one card instead of hiding and showing it.
@MainActor
final class SidebarRailHoverCards: HoverCardSource {
    weak var rail: SidebarRailView?
    /// The app's coordinator, read when needed (the App injects it into the sidebar after init).
    var coordinator: () -> HoverCardCoordinator? = { nil }
    /// The digit whose Cmd-digit selects `id`, if any.
    var digit: (WorkspaceID) -> Int? = { _ in nil }
    private let body = SidebarRailCardView()

    static func targetID(_ id: WorkspaceID) -> HoverTargetID { HoverTargetID("rail:\(id.rawValue)") }

    private func workspaceID(_ id: HoverTargetID) -> WorkspaceID? {
        guard id.rawValue.hasPrefix("rail:") else { return nil }
        return WorkspaceID(String(id.rawValue.dropFirst("rail:".count)))
    }

    /// The pointer moved over, onto or off the rail (`screenPoint`): the coordinator hit-tests.
    func pointerMoved(to screenPoint: CGPoint?) {
        guard let coordinator = coordinator() else { return }
        coordinator.register(self)
        coordinator.pointerMoved(to: screenPoint)
    }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { rail?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let rail, let window = rail.window, !rail.isHiddenOrHasHiddenAncestor else { return nil }
        let point = rail.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard let tick = rail.tick(at: point), case let .workspace(id) = tick.mark.target,
              let anchor = rail.cardAnchor(tick) else { return nil }
        let target = HoverTarget(id: Self.targetID(id), window: window.windowNumber, delay: DesignSettings.shared.hoverCardDelay,
                                 leave: .hides(reshow: HoverCardTiming.reshowWindow))
        return HoverCardHit(target: target, anchor: anchor)
    }

    /// Between two rows of the rail (a group gap): the card waits for the next row.
    func hoverCardBridges(at screenPoint: CGPoint) -> Bool {
        guard let rail, let window = rail.window, !rail.isHiddenOrHasHiddenAncestor,
              let first = rail.railLayout.ticks.first, let last = rail.railLayout.ticks.last else { return false }
        let point = rail.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return rail.bounds.contains(point) && point.y >= first.rowY && point.y < last.rowY + rail.railLayout.pitch
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        guard let rail, let ws = workspaceID(id),
              let tick = rail.railLayout.ticks.first(where: { $0.mark.target == .workspace(ws) }) else { return nil }
        return rail.cardAnchor(tick)
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let rail, let ws = workspaceID(id), let model = rail.model, let workspace = model.workspace(ws),
              let tick = rail.railLayout.ticks.first(where: { $0.mark.target == .workspace(ws) }) else { return nil }
        body.configure(title: workspace.title, state: tick.mark.state, digit: digit(ws))
        return HoverCardBody(view: body, placement: .besideRow, themeAnchor: rail) { [weak body] in body?.applyColors() }
    }

    func hoverCardActivated(_ id: HoverTargetID) {}
    func hoverCardDeactivated(_ id: HoverTargetID) {}
}

/// The rail's card: the workspace's name, a dot for unread (the unread color) or working, and the
/// Cmd-digit that selects it. One line; reused for every mark.
@MainActor
final class SidebarRailCardView: NSView, HoverCardTextReporting {
    private let title = ChromeLabel(labelWithString: "")
    private let key = ChromeLabel(labelWithString: "")
    private let dot = NSView()
    private var state: SidebarRailMark.State = .idle
    static var maxWidth: CGFloat { 280 }

    var reportedLines: [String] { [title.stringValue, key.stringValue].filter { !$0.isEmpty } }

    init() {
        super.init(frame: .zero)
        title.font = Typography.bodyEmphasized
        title.lineBreakMode = .byTruncatingTail
        key.font = Typography.caption
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        let stack = NSStackView(views: [dot, title, key])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Metrics.space3
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, state: SidebarRailMark.State, digit: Int?) {
        title.stringValue = text
        key.stringValue = digit.map { "⌘\($0)" } ?? ""
        key.isHidden = digit == nil
        self.state = state
        dot.isHidden = state == .idle
        setAccessibilityLabel(text)
        applyColors()
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            key.textColor = Palette.textTertiary
            // glass-opaque-allow: a 6 pt unread/working status dot inside the card, not a surface; the card is the shared glass panel
            dot.layer?.backgroundColor = (state == .unread ? Palette.notificationBlue : Palette.textSecondary).cgColor
        }
    }
}
