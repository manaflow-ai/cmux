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
///
/// Views observe one ``AppSceneNodeSlot`` per node, never the whole scene: a batch
/// re-renders only the nodes it touched (a custom sidebar's one-row update costs one row at
/// any row count, plans/cmux-next/custom-sidebar-DESIGN.md). Whole-scene readers observe
/// `revision`.
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

    /// The current scene. Not observed: views read their node's slot, whole-scene readers
    /// observe `revision`.
    @ObservationIgnored public private(set) var scene = AppScene()
    /// Bumped once per batch that changed the scene.
    public private(set) var revision = 0
    /// The root node's id.
    public private(set) var root: String?
    public var status: Status = .loading
    @ObservationIgnored private var slots: [String: AppSceneNodeSlot] = [:]
    public weak var interaction: (any AppSceneInteraction)?

    public init(status: Status = .loading) {
        self.status = status
    }

    /// Applies one batch; a budget refusal fails the mount (the runtime
    /// itself refuses to emit past its budgets, so this means a bad VM).
    public func apply(_ ops: [AppSceneOp]) {
        var touched = Set<String>()
        let issues = scene.apply(ops, touched: &touched)
        if scene.root != root { root = scene.root }
        if !touched.isEmpty {
            revision &+= 1
            refreshSlots(touched)
        }
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
        root = nil
        revision &+= 1
        for slot in slots.values { slot.set(node: nil, children: []) }
        slots.removeAll()
        status = .loading
    }

    /// The observable view of node `id` (created on first read; the node may not exist yet).
    public func slot(_ id: String) -> AppSceneNodeSlot {
        if let slot = slots[id] { return slot }
        let slot = AppSceneNodeSlot(node: scene[id], children: scene.flattenedChildren(of: id))
        slots[id] = slot
        return slot
    }

    /// Writes the slots of the touched nodes, plus the parents that lay a touched inline node's
    /// children out in place (a ForEach's new order changes its stack's flattened children).
    private func refreshSlots(_ touched: Set<String>) {
        var dirty = touched
        for id in touched {
            var current = id
            while scene[current]?.type.isInline == true, let up = scene.parent(of: current), dirty.insert(up).inserted {
                current = up
            }
        }
        for id in dirty {
            guard let slot = slots[id] else { continue }
            guard let node = scene[id] else {
                slot.set(node: nil, children: [])
                slots.removeValue(forKey: id)
                continue
            }
            slot.set(node: node, children: scene.flattenedChildren(of: id))
        }
    }

    func send(_ node: String, _ event: String, _ payload: AppJSON = .object([:])) {
        interaction?.dispatch(node: node, event: event, payload: payload)
    }
}
