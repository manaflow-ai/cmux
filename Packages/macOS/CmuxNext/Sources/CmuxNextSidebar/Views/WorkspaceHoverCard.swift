import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources
import CmuxNextWakeups

/// The workspace hover card (Codex parity, Leo 2026-10-08): a title row
/// (the name, a kind or host icon, the relative age) and one row per
/// meaningful fact (`WorkspaceHoverCardContent`); CPU and memory summed over
/// its tabs show as one muted line, only when notable. It replaces the row
/// tooltip.
///
/// Resources are sampled from hover start (the CPU baseline) until the
/// card hides; nothing is sampled while no card is pending or shown.
final class WorkspaceHoverCardController: HoverCardSource {
    let resources = ResourceCardSampler(source: nil)
    /// Hover time before the first card: none, the card shows on the first
    /// hit (Leo 2026-10-08); moving down the list slides it over.
    var delay: Duration = .zero
    weak var list: SidebarListView?
    /// The app's one coordinator; the App injects it.
    var coordinator: HoverCardCoordinator {
        didSet {
            guard coordinator !== oldValue else { return }
            oldValue.unregister(self)
            if list?.window != nil { coordinator.register(self) }
        }
    }
    private var body: WorkspaceHoverCardView?
    private var bodyID: HoverTargetID?

    init(coordinator: HoverCardCoordinator = HoverCardCoordinator()) {
        self.coordinator = coordinator
    }

    static func targetID(_ id: WorkspaceID) -> HoverTargetID { HoverTargetID("ws:\(id.rawValue)") }

    private func workspaceID(_ id: HoverTargetID) -> WorkspaceID? {
        id.rawValue.hasPrefix("ws:") ? WorkspaceID(String(id.rawValue.dropFirst(3))) : nil
    }

    /// This list's workspace whose card shows now.
    var shownID: WorkspaceID? {
        guard let id = coordinator.machine.shownTarget?.id, let ws = workspaceID(id), list?.workspaces[ws] != nil else { return nil }
        return ws
    }

    var isVisible: Bool { shownID != nil }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { list?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let list, let window = list.window,
              let id = list.hoverCardWorkspace(at: list.convert(window.convertPoint(fromScreen: screenPoint), from: nil)),
              let anchor = list.hoverCardAnchor(for: id)
        else { return nil }
        return HoverCardHit(target: HoverTarget(id: Self.targetID(id), window: window.windowNumber, delay: delay), anchor: anchor)
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        workspaceID(id).flatMap { list?.hoverCardAnchor(for: $0) }
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let list, let ws = workspaceID(id), let workspace = list.workspaces[ws] else { return nil }
        let body = body ?? WorkspaceHoverCardView()
        self.body = body
        let machine = list.sections.values.lazy.compactMap(\.machine).first { $0.id == workspace.machineID }
        body.configure(WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date()))
        body.setResources(resources.report)
        bodyID = id
        return HoverCardBody(view: body, placement: .beside, themeAnchor: list) { [weak body] in body?.applyColors() }
    }

    func hoverCardActivated(_ id: HoverTargetID) {
        guard let ws = workspaceID(id) else { return }
        resources.open(.workspace(ws.rawValue)) { [weak self] report in
            guard let self, self.bodyID == id else { return }
            self.body?.setResources(report)
            self.coordinator.contentChanged(id)
        }
    }

    func hoverCardDeactivated(_ id: HoverTargetID) {
        resources.close()
        bodyID = nil
    }

    /// Design tokens changed: the next card rebuilds at the new sizes.
    func tokensChanged() {
        coordinator.dismiss(.action)
        body = nil
        bodyID = nil
    }
}

/// The workspace card body. One instance is reused for every workspace
/// card; the app's one `HoverCardPanel` hosts it.
final class WorkspaceHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space4 }
    static var cardWidth: CGFloat { 280 }
    private static var iconSize: CGFloat { 13 }

    private let titleLabel = NSTextField(labelWithString: "")
    private let kindIcon = NSImageView()
    private let ageLabel = NSTextField(labelWithString: "")
    private let factsStack = NSStackView()
    private let resourceLabel = NSTextField(labelWithString: "")
    private var factViews: [(icon: NSImageView, label: NSTextField)] = []

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = Typography.bodyEmphasized
        // The whole name, wrapped: the card is where a clipped row title
        // reads in full (also under Reduce Motion, which has no marquee).
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 6
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ageLabel.font = Typography.caption
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.setContentHuggingPriority(.required, for: .horizontal)
        resourceLabel.font = Typography.caption
        resourceLabel.lineBreakMode = .byTruncatingTail

        let titleRow = NSStackView(views: [titleLabel, kindIcon, ageLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Metrics.space2
        titleRow.setCustomSpacing(Metrics.space4, after: kindIcon)
        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = Metrics.space2

        let stack = NSStackView(views: [titleRow, factsStack, resourceLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            factsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kindIcon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            kindIcon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the card shows, one entry per row (tests, accessibility).
    var lines: [String] {
        var lines = [[titleLabel.stringValue, ageLabel.isHidden ? "" : ageLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: " ")]
        lines += factViews.filter { !$0.label.isHidden }.map(\.label.stringValue)
        if !resourceLabel.isHidden { lines.append(resourceLabel.stringValue) }
        return lines
    }

    func configure(_ content: WorkspaceHoverCardContent) {
        titleLabel.stringValue = content.title
        kindIcon.image = NSImage.icon(content.icon, size: Self.iconSize)
        ageLabel.stringValue = content.age ?? ""
        ageLabel.isHidden = content.age == nil
        // The width the title wraps at (the panel sizes the card in one
        // pass): the row less its icon and the age.
        let age = ageLabel.isHidden ? 0 : ageLabel.intrinsicContentSize.width + Metrics.space4
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding - Self.iconSize - Metrics.space2 - age
        while factViews.count < content.facts.count { addFactRow() }
        for (index, row) in factViews.enumerated() {
            let fact = index < content.facts.count ? content.facts[index] : nil
            row.icon.superview?.isHidden = fact == nil
            row.label.isHidden = fact == nil
            guard let fact else { continue }
            row.icon.image = NSImage.icon(fact.icon, size: Self.iconSize)
            row.label.stringValue = fact.text
        }
        factsStack.isHidden = content.facts.isEmpty
        applyColors()
    }

    func setResources(_ report: ResourceReport?) {
        let line = WorkspaceHoverCardContent.resourceLine(report)
        resourceLabel.stringValue = line ?? ""
        resourceLabel.isHidden = line == nil
    }

    private func addFactRow() {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        factsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true
        factViews.append((icon, label))
    }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            ageLabel.textColor = Palette.textSecondary
            kindIcon.contentTintColor = Palette.textSecondary
            for row in factViews {
                row.label.textColor = Palette.textPrimary
                row.icon.contentTintColor = Palette.textSecondary
            }
            resourceLabel.textColor = Palette.textSecondary
        }
    }
}
