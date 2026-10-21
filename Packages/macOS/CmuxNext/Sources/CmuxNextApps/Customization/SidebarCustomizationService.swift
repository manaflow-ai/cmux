import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import Observation

/// The user's sidebar customization from the app platform (cx-swovq.1, cx-swovq.2; Lawrence
/// 2026-10-14: the app platform is the engine). The app that implements `cmux.hovercard/1` draws
/// the hover card of the row it gets as `ctx.target`; the one that implements
/// `cmux.sidebar.rows/1` decorates rows. The user's own folder app (`local/customize`) wins over
/// any other. Scripts run in the daemon's sandboxed app host; this only mounts and hosts.
@MainActor
@Observable
public final class SidebarCustomizationService: SidebarCustomization {
    static let hoverCardInterface = "cmux.hovercard/1"
    static let rowsInterface = "cmux.sidebar.rows/1"
    static let userApp = "local/customize"

    @ObservationIgnored private let client: AppsClient
    @ObservationIgnored private let isPresented: (String) -> Bool
    /// Each decorated row's overrides; the sidebar bridge reads it inside its row observation.
    public private(set) var rowDecorations: [String: SidebarRowDecoration] = [:]
    @ObservationIgnored public var onRowDecorationsChange: (() -> Void)?
    @ObservationIgnored private var rowsMount: AppMount?
    @ObservationIgnored private var rowsKey: String?
    @ObservationIgnored private var appsWatch: Task<Void, Never>?
    @ObservationIgnored private var sceneWatch: Task<Void, Never>?

    public init(client: AppsClient, isPresented: @escaping (String) -> Bool) {
        self.client = client
        self.isPresented = isPresented
        // task-owner: the service lives as long as the app; one watch of which app decorates rows.
        appsWatch = Task { [weak self] in
            // A trigger: the same key remounts after a failed render (a fixed script keeps its version).
            for await key in ObservationStream({ [weak self] in ObservationTrigger(self?.implementationKey(Self.rowsInterface)) }) {
                self?.mountRows(key.value)
            }
        }
    }

    /// The user's own app (`local/customize`) when it implements `interface`. Only it may redraw
    /// the card (it gets the card's fields with no scope) or restyle rows (a badge reads like a
    /// status): another installed app cannot.
    func implementation(_ interface: String) -> (app: String, implementation: AppImplementation)? {
        guard let app = client.app(Self.userApp), isPresented(app.id),
              let found = app.manifest.implementations.first(where: { $0.interface == interface && $0.hasScene }) else { return nil }
        return (app.id, found)
    }

    /// `app#implementation@version`: a new version remounts (a reloaded script).
    private func implementationKey(_ interface: String) -> String? {
        guard let (app, found) = implementation(interface) else { return nil }
        return "\(app)#\(found.id)@\(client.app(app)?.manifest.version ?? "")"
    }

    public func hoverCard(forWorkspace id: String, card: SidebarCardFacts) -> (any SidebarCustomContent)? {
        guard let (app, found) = implementation(Self.hoverCardInterface) else { return nil }
        let target: AppJSON = .object(["kind": .string("workspace"), "id": .string(id)])
        let mount = client.mount(app, implementation: found, surface: "hoverCard", context: ["target": target, "card": Self.json(card)])
        return AppHoverCardContent(mount: mount, client: client)
    }

    /// `ctx.card`: {title, status, statusSinceMs, age, facts: [{kind, text, sinceMs}]}.
    static func json(_ card: SidebarCardFacts) -> AppJSON {
        func optional(_ text: String?) -> AppJSON { text.map(AppJSON.string) ?? .null }
        func number(_ value: Double?) -> AppJSON { value.map(AppJSON.number) ?? .null }
        return .object([
            "title": .string(card.title), "status": optional(card.status), "statusSinceMs": number(card.statusSinceMs),
            "age": optional(card.age),
            "facts": .array(card.facts.map { .object(["kind": .string($0.kind), "text": .string($0.text), "sinceMs": number($0.sinceMs)]) }),
        ])
    }

    private func mountRows(_ key: String?) {
        // The same key remounts after a failed render: a fixed script keeps its version.
        var failed = false
        if case .failed? = rowsMount?.model.status { failed = true }
        guard key != rowsKey || failed else { return }
        rowsKey = key
        sceneWatch?.cancel()
        if let rowsMount { client.unmount(rowsMount) }
        rowsMount = nil
        guard key != nil, let (app, found) = implementation(Self.rowsInterface) else {
            setDecorations([:])
            return
        }
        let mount = client.mount(app, implementation: found, surface: "sidebarRows")
        rowsMount = mount
        let model = mount.model
        // task-owner: one watch per rows mount, cancelled when it remounts.
        sceneWatch = Task { [weak self] in
            for await scene in ObservationStream({ model.scene }) {
                self?.setDecorations(Self.decorations(scene))
            }
        }
    }

    private func setDecorations(_ next: [String: SidebarRowDecoration]) {
        guard next != rowDecorations else { return }
        rowDecorations = next
        onRowDecorationsChange?()
    }

    /// Every `Group` node with a `row` prop, read as a decoration (later nodes win).
    static func decorations(_ scene: AppScene) -> [String: SidebarRowDecoration] {
        var out: [String: SidebarRowDecoration] = [:]
        for node in scene.nodes.values where node.type == .group {
            var props: [String: String] = [:]
            for key in ["row", "icon", "weight", "indicator", "badge"] { props[key] = node.string(key) }
            if let (id, decoration) = SidebarRowDecoration.parse(props) { out[id] = decoration }
        }
        return out
    }
}

/// One mounted custom hover card: the scene's hosting view, ready once its first scene arrives,
/// failed with the host's reason.
@MainActor
final class AppHoverCardContent: SidebarCustomContent {
    private let mount: AppMount
    private weak var client: AppsClient?
    let view: NSView
    var onChange: (() -> Void)?
    private var watch: Task<Void, Never>?

    init(mount: AppMount, client: AppsClient) {
        self.mount = mount
        self.client = client
        view = mount.makeView()
        let model = mount.model
        // task-owner: lives while the card shows; release() cancels it.
        watch = Task { [weak self] in
            for await _ in ObservationStream({ (model.status, model.scene) }) {
                self?.onChange?()
            }
        }
    }

    var isReady: Bool { mount.model.status == .ready }

    var errorText: String? {
        switch mount.model.status {
        case .failed(let reason), .disconnected(let reason): reason
        case .loading, .ready: nil
        }
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        (view as? AppSceneHostingView)?.preferredHeight(width: width) ?? view.fittingSize.height
    }

    func release() {
        watch?.cancel()
        watch = nil
        client?.unmount(mount)
    }
}
