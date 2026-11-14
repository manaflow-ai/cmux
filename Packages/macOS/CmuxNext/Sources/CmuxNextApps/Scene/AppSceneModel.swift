public import Observation

/// Where a rendered scene sends user input: the mount, which forwards it to
/// the app supervisor (`apps-dispatch` with origin `user`; tap, menu, move,
/// edit, submit, cancel). The supervisor mints the gesture token.
@MainActor
public protocol AppSceneInteraction: AnyObject {
    func dispatch(node: String, event: String, payload: AppJSON)
    /// Runs the app's script again from its saved files and draws it anew (a failed mount's Reload).
    func reload()
}

extension AppSceneInteraction {
    public func reload() {}
}

/// The observable mirror of one mounted contribution, for `AppSceneHostingView`.
/// Written only by the supervisor's scene stream for the mount (`apps-scene`);
/// hover and press stay in the views.
@MainActor
@Observable
public final class AppSceneModel {
    public enum Status: Sendable, Hashable {
        case loading
        case ready
        /// Render failed, the app host stopped, or a budget was exceeded.
        case failed(String)
        /// The supervisor is unreachable (the reason says why); the mount
        /// renders again after the reconnect.
        case disconnected(String)
    }

    public private(set) var scene = AppScene()
    public var status: Status = .loading
    /// Why the app's last saved script did not load while this view kept drawing the script before
    /// it (`apps-reload-failed`); nil once a scene of a script that loaded replaces it.
    public var reloadFailure: String?
    /// Counts applied batches and resets, so an AppKit renderer can tell in `layout()` whether the
    /// scene changed since it last drew, without comparing scenes.
    @ObservationIgnored public private(set) var revision = 0
    public weak var interaction: (any AppSceneInteraction)?

    public init(status: Status = .loading) {
        self.status = status
    }

    /// Applies one batch; a budget refusal fails the mount (the runtime
    /// itself refuses to emit past its budgets, so this means a bad VM).
    public func apply(_ ops: [AppSceneOp]) {
        let issues = scene.apply(ops)
        revision &+= 1
        if let issue = issues.first {
            switch issue {
            case .nodeBudget: status = .failed("app.limit: more than \(AppScene.maxNodes) scene nodes")
            case .depthBudget: status = .failed("app.limit: scene deeper than \(AppScene.maxDepth)")
            case .duplicateID(let id): status = .failed("scene op reused node id \(id)")
            }
        } else if scene.root != nil, status == .loading {
            status = .ready
        }
    }

    public func reset() {
        scene = AppScene()
        status = .loading
        // A new scene comes from a script that loaded: the refused save is behind it.
        reloadFailure = nil
        revision &+= 1
    }

    /// The error card's Reload: the mount's app runs its script again and every view of it redraws.
    public func reload() {
        interaction?.reload()
    }

    func send(_ node: String, _ event: String, _ payload: AppJSON = .object([:])) {
        interaction?.dispatch(node: node, event: event, payload: payload)
    }
}
