public import Observation

/// Where a rendered scene sends user input: the mount, which forwards it to
/// the app supervisor (`apps-dispatch` with origin `user`; tap, menu, move,
/// edit, submit, cancel). The supervisor mints the gesture token.
@MainActor
public protocol AppSceneInteraction: AnyObject {
    func dispatch(node: String, event: String, payload: AppJSON)
}

/// The observable mirror of one mounted contribution, for `AppSceneView`.
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
    public weak var interaction: (any AppSceneInteraction)?

    public init(status: Status = .loading) {
        self.status = status
    }

    /// Applies one batch; a budget refusal fails the mount (the runtime
    /// itself refuses to emit past its budgets, so this means a bad VM).
    public func apply(_ ops: [AppSceneOp]) {
        let issues = scene.apply(ops)
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
    }

    func send(_ node: String, _ event: String, _ payload: AppJSON = .object([:])) {
        interaction?.dispatch(node: node, event: event, payload: payload)
    }
}
