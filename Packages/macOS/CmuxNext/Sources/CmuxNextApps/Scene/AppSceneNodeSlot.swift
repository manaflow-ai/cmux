public import Observation

/// One scene node as views observe it: its props and its children with inline nodes (Group,
/// ForEach) laid out in place. ``AppSceneModel`` writes a slot only when a batch touched its
/// node, and only with a changed value, so a view re-renders only for its own node.
@MainActor
@Observable
public final class AppSceneNodeSlot {
    /// The node; nil once removed (or before it is created).
    public private(set) var node: AppSceneNode?
    /// ``AppScene/flattenedChildren(of:)`` of the node.
    public private(set) var children: [String]

    init(node: AppSceneNode?, children: [String]) {
        self.node = node
        self.children = children
    }

    func set(node: AppSceneNode?, children: [String]) {
        if node != self.node { self.node = node }
        if children != self.children { self.children = children }
    }
}
