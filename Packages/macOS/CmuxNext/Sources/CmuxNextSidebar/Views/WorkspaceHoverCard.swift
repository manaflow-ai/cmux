import AppKit
import CmuxNextDesign
import CmuxNextResources
import CmuxNextWakeups

/// The workspace hover card: title, cwd, and the workspace's CPU and memory
/// summed over its tabs (each process once), its heaviest tabs, and the
/// shared processes on their own line. It replaces the row tooltip.
///
/// Resources are sampled from hover start (the CPU baseline) until the
/// card hides; nothing is sampled while no card is pending or shown.
final class WorkspaceHoverCardController: HoverCardSource {
    let resources = ResourceCardSampler(source: nil)
    /// Hover time before the first card; later cards show at once while one
    /// is visible (moving down the list), by the coordinator's rules.
    var delay: Duration = .milliseconds(600)
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
        body.configure(workspace)
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
    private static var padding: CGFloat { Metrics.space5 }
    static var cardWidth: CGFloat { 280 }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    let resources = ResourceSummaryView()

    init() {
        super.init(frame: .zero)
        let content = self
        titleLabel.font = Typography.bodyEmphasized
        // The whole name, wrapped: the card is where a clipped row title
        // reads in full (also under Reduce Motion, which has no marquee).
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 6
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        subtitleLabel.font = Typography.caption
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        resources.style = .workspace(topConsumers: 3)

        let stack = NSStackView(views: [titleLabel, subtitleLabel, resources])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.setCustomSpacing(Metrics.space3, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resources.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ workspace: SidebarWorkspace) {
        titleLabel.stringValue = workspace.title
        subtitleLabel.stringValue = workspace.folderLine ?? ""
        subtitleLabel.isHidden = workspace.folderLine == nil
    }

    func setResources(_ report: ResourceReport?) {
        resources.show(report)
    }
}

extension WorkspaceHoverCardView {
    /// Recolors the labels in the card's theme scope; the panel runs it on
    /// adopt and on every change of that scope.
    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            subtitleLabel.textColor = Palette.textSecondary
        }
    }
}
