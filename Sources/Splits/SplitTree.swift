import CoreGraphics
import Foundation

/// SplitTree represents a tree of views that can be divided.
struct SplitTree<ViewType: AnyObject & Identifiable> {
    /// The root of the tree. This can be nil to indicate the tree is empty.
    let root: Node?

    /// The node that is currently zoomed. A zoomed split is expected to take up the full
    /// size of the view area where the splits are shown.
    let zoomed: Node?

    /// A single node in the tree is either a leaf node (a view) or a split (has a
    /// left/right or top/bottom).
    indirect enum Node {
        case leaf(view: ViewType)
        case split(Split)

        struct Split: Equatable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
    }

    enum Direction: Hashable {
        case horizontal // Splits are laid out left and right
        case vertical // Splits are laid out top and bottom
    }

    /// The path to a specific node in the tree.
    struct Path {
        let path: [Component]

        var isEmpty: Bool { path.isEmpty }

        enum Component {
            case left
            case right
        }
    }

    /// Spatial representation of the split tree. This can be used to better understand
    /// its physical representation to perform tasks such as navigation.
    struct Spatial {
        let slots: [Slot]

        /// A single slot within the spatial mapping of a tree. Note that the bounds are
        /// _relative_. They can't be mapped to physical pixels because the SplitTree
        /// isn't aware of actual rendering. But relative to each other the bounds are
        /// correct.
        struct Slot {
            let node: Node
            let bounds: CGRect
        }

        /// Direction for spatial navigation within the split tree.
        enum Direction {
            case left
            case right
            case up
            case down
        }
    }

    enum SplitError: Error {
        case viewNotFound
    }

    enum NewDirection {
        case left
        case right
        case down
        case up
    }

    /// The direction that focus can move from a node.
    enum FocusDirection {
        // Follow a consistent tree-like structure.
        case previous
        case next

        // Spatially-aware navigation targets. These take into account the
        // layout to find the spatially correct node to move to. Spatial navigation
        // is always from the top-left corner for now.
        case spatial(Spatial.Direction)
    }
}

// MARK: SplitTree

extension SplitTree {
    var isEmpty: Bool {
        root == nil
    }

    /// Returns true if this tree is split.
    var isSplit: Bool {
        if case .split = root { true } else { false }
    }

    init() {
        self.init(root: nil, zoomed: nil)
    }

    init(view: ViewType) {
        self.init(root: .leaf(view: view), zoomed: nil)
    }

    /// Checks if the tree contains the specified node.
    func contains(_ node: Node) -> Bool {
        guard let root else { return false }
        return root.path(to: node) != nil
    }

    /// Checks if the tree contains the specified view.
    func contains(_ view: ViewType) -> Bool {
        guard let root else { return false }
        return root.node(view: view) != nil
    }

    /// Insert a new view at the given view point by creating a split in the given direction.
    /// This will always reset the zoomed state of the tree.
    func inserting(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        return .init(
            root: try root.inserting(view: view, at: at, direction: direction),
            zoomed: nil)
    }

    /// Find a node containing a view with the specified ID.
    func find(id: ViewType.ID) -> Node? {
        guard let root else { return nil }
        return root.find(id: id)
    }

    /// Remove a node from the tree. If the node being removed is part of a split,
    /// the sibling node takes the place of the parent split.
    func removing(_ target: Node) -> Self {
        guard let root else { return self }

        if root == target {
            return .init(root: nil, zoomed: nil)
        }

        let newRoot = root.remove(target)
        let newZoomed = (zoomed == target) ? nil : zoomed
        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Replace a node in the tree with a new node.
    func replacing(node: Node, with newNode: Node) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        let newRoot = try root.replacingNode(at: path, with: newNode)
        let newZoomed = (zoomed == node) ? newNode : zoomed
        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Find the next view to focus based on the current focused node and direction.
    func focusTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
        guard let root else { return nil }

        switch direction {
        case .previous:
            let allLeaves = root.leaves()
            let currentView = currentNode.leftmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(before: currentIndex)
            return allLeaves[index]

        case .next:
            let allLeaves = root.leaves()
            let currentView = currentNode.rightmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(after: currentIndex)
            return allLeaves[index]

        case .spatial(let spatialDirection):
            let spatial = root.spatial()
            let nodes = spatial.slots(in: spatialDirection, from: currentNode)
            if nodes.isEmpty {
                return nil
            }

            let bestNode = nodes.first(where: {
                if case .leaf = $0.node { return true } else { return false }
            }) ?? nodes[0]
            switch bestNode.node {
            case .leaf(let view):
                return view
            case .split:
                return switch (spatialDirection) {
                case .up, .left: bestNode.node.leftmostLeaf()
                case .down, .right: bestNode.node.rightmostLeaf()
                }
            }
        }
    }

    /// Equalize all splits in the tree so that each split's ratio is based on the
    /// relative weight (number of leaves) of its children.
    func equalized() -> Self {
        guard let root else { return self }
        let newRoot = root.equalize()
        return .init(root: newRoot, zoomed: zoomed)
    }

    /// Resize a node in the tree by the given pixel amount in the specified direction.
    func resizing(node: Node, by pixels: UInt16, in direction: Spatial.Direction, with bounds: CGRect) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        let targetSplitDirection: Direction = switch direction {
        case .up, .down: .vertical
        case .left, .right: .horizontal
        }

        var splitPath: Path?
        var splitNode: Node?

        for i in stride(from: path.path.count - 1, through: 0, by: -1) {
            let parentPath = Path(path: Array(path.path.prefix(i)))
            if let parent = root.node(at: parentPath), case .split(let split) = parent {
                if split.direction == targetSplitDirection {
                    splitPath = parentPath
                    splitNode = parent
                    break
                }
            }
        }

        guard let splitPath = splitPath,
              let splitNode = splitNode,
              case .split(let split) = splitNode else {
            throw SplitError.viewNotFound
        }

        let spatial = root.spatial(within: bounds.size)
        guard let splitSlot = spatial.slots.first(where: { $0.node == splitNode }) else {
            throw SplitError.viewNotFound
        }

        let pixelOffset = Double(pixels)
        let newRatio: Double

        switch (split.direction, direction) {
        case (.horizontal, .left):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.width)))
        case (.horizontal, .right):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.width)))
        case (.vertical, .up):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.height)))
        case (.vertical, .down):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.height)))
        default:
            throw SplitError.viewNotFound
        }

        let newSplit = Node.Split(
            direction: split.direction,
            ratio: newRatio,
            left: split.left,
            right: split.right
        )

        let newRoot = try root.replacingNode(at: splitPath, with: .split(newSplit))
        return .init(root: newRoot, zoomed: nil)
    }
}

// MARK: SplitTree.Node

extension SplitTree.Node {
    typealias Node = SplitTree.Node
    typealias NewDirection = SplitTree.NewDirection
    typealias SplitError = SplitTree.SplitError
    typealias Path = SplitTree.Path

    /// Find a node containing a view with the specified ID.
    func find(id: ViewType.ID) -> Node? {
        switch self {
        case .leaf(let view):
            return view.id == id ? self : nil
        case .split(let split):
            if let found = split.left.find(id: id) {
                return found
            }
            return split.right.find(id: id)
        }
    }

    /// Returns the node in the tree that contains the given view.
    func node(view: ViewType) -> Node? {
        switch self {
        case .leaf(let nodeView):
            return nodeView === view ? self : nil
        case .split(let split):
            if let result = split.left.node(view: view) {
                return result
            } else if let result = split.right.node(view: view) {
                return result
            }
            return nil
        }
    }

    /// Returns the path to a given node in the tree.
    func path(to node: Self) -> Path? {
        var components: [Path.Component] = []
        func search(_ current: Self) -> Bool {
            if current == node {
                return true
            }

            switch current {
            case .leaf:
                return false
            case .split(let split):
                components.append(.left)
                if search(split.left) {
                    return true
                }
                components.removeLast()

                components.append(.right)
                if search(split.right) {
                    return true
                }
                components.removeLast()
                return false
            }
        }

        return search(self) ? Path(path: components) : nil
    }

    /// Returns the node at the given path from this node as root.
    func node(at path: Path) -> Node? {
        if path.isEmpty {
            return self
        }

        guard case .split(let split) = self else {
            return nil
        }

        let component = path.path[0]
        let remainingPath = Path(path: Array(path.path.dropFirst()))

        switch component {
        case .left:
            return split.left.node(at: remainingPath)
        case .right:
            return split.right.node(at: remainingPath)
        }
    }

    /// Inserts a new view into the split tree by creating a split at the location of an existing view.
    func inserting(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        guard let path = path(to: .leaf(view: at)) else {
            throw SplitError.viewNotFound
        }

        let splitDirection: SplitTree.Direction
        let newViewOnLeft: Bool
        switch direction {
        case .left:
            splitDirection = .horizontal
            newViewOnLeft = true
        case .right:
            splitDirection = .horizontal
            newViewOnLeft = false
        case .up:
            splitDirection = .vertical
            newViewOnLeft = true
        case .down:
            splitDirection = .vertical
            newViewOnLeft = false
        }

        let newNode: Node = .split(.init(
            direction: splitDirection,
            ratio: 0.5,
            left: newViewOnLeft ? .leaf(view: view) : .leaf(view: at),
            right: newViewOnLeft ? .leaf(view: at) : .leaf(view: view)
        ))

        return try replacingNode(at: path, with: newNode)
    }

    /// Replace a node at the specified path with a new node.
    func replacingNode(at path: Path, with newNode: Node) throws -> Node {
        if path.isEmpty {
            return newNode
        }

        guard case .split(let split) = self else {
            throw SplitError.viewNotFound
        }

        let component = path.path[0]
        let remainingPath = Path(path: Array(path.path.dropFirst()))

        switch component {
        case .left:
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: try split.left.replacingNode(at: remainingPath, with: newNode),
                right: split.right
            ))
        case .right:
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left,
                right: try split.right.replacingNode(at: remainingPath, with: newNode)
            ))
        }
    }

    /// Remove a node from the tree.
    func remove(_ target: Node) -> Node? {
        if self == target {
            return nil
        }

        switch self {
        case .leaf:
            return self
        case .split(let split):
            let newLeft = split.left.remove(target)
            let newRight = split.right.remove(target)

            if newLeft == nil && newRight == nil {
                return nil
            } else if newLeft == nil {
                return newRight
            } else if newRight == nil {
                return newLeft
            }

            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    /// Resize a split node to the specified ratio.
    func resizing(to ratio: Double) -> Self {
        switch self {
        case .leaf:
            return self
        case .split(let split):
            return .split(.init(
                direction: split.direction,
                ratio: ratio,
                left: split.left,
                right: split.right
            ))
        }
    }

    /// Get the leftmost leaf in this subtree.
    func leftmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.left.leftmostLeaf()
        }
    }

    /// Get the rightmost leaf in this subtree.
    func rightmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.right.rightmostLeaf()
        }
    }

    /// Equalize this node and all its children.
    func equalize() -> Node {
        let (equalizedNode, _) = equalizeWithWeight()
        return equalizedNode
    }

    private func equalizeWithWeight() -> (node: Node, weight: Int) {
        switch self {
        case .leaf:
            return (self, 1)
        case .split(let split):
            let leftWeight = split.left.weightForDirection(split.direction)
            let rightWeight = split.right.weightForDirection(split.direction)
            let totalWeight = leftWeight + rightWeight
            let newRatio = Double(leftWeight) / Double(totalWeight)
            let (leftNode, _) = split.left.equalizeWithWeight()
            let (rightNode, _) = split.right.equalizeWithWeight()
            let newSplit = Split(
                direction: split.direction,
                ratio: newRatio,
                left: leftNode,
                right: rightNode
            )
            return (.split(newSplit), totalWeight)
        }
    }

    private func weightForDirection(_ direction: SplitTree.Direction) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            if split.direction == direction {
                return split.left.weightForDirection(direction) + split.right.weightForDirection(direction)
            }
            return 1
        }
    }

    /// Returns all leaf nodes in order.
    func leaves() -> [ViewType] {
        switch self {
        case .leaf(let view):
            return [view]
        case .split(let split):
            return split.left.leaves() + split.right.leaves()
        }
    }
}

// MARK: SplitTree.Node Spatial

extension SplitTree.Node {
    func spatial(within bounds: CGSize? = nil) -> SplitTree.Spatial {
        let width: Double
        let height: Double
        if let bounds {
            width = bounds.width
            height = bounds.height
        } else {
            let (w, h) = self.dimensions()
            width = Double(w)
            height = Double(h)
        }

        let slots = spatialSlots(in: CGRect(x: 0, y: 0, width: width, height: height))
        return SplitTree.Spatial(slots: slots)
    }

    private func dimensions() -> (width: UInt, height: UInt) {
        switch self {
        case .leaf:
            return (1, 1)
        case .split(let split):
            let leftDimensions = split.left.dimensions()
            let rightDimensions = split.right.dimensions()

            switch split.direction {
            case .horizontal:
                return (
                    width: leftDimensions.width + rightDimensions.width,
                    height: Swift.max(leftDimensions.height, rightDimensions.height)
                )
            case .vertical:
                return (
                    width: Swift.max(leftDimensions.width, rightDimensions.width),
                    height: leftDimensions.height + rightDimensions.height
                )
            }
        }
    }

    private func spatialSlots(in bounds: CGRect) -> [SplitTree.Spatial.Slot] {
        switch self {
        case .leaf:
            return [.init(node: self, bounds: bounds)]
        case .split(let split):
            let leftBounds: CGRect
            let rightBounds: CGRect

            switch split.direction {
            case .horizontal:
                let splitX = bounds.minX + bounds.width * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * split.ratio,
                    height: bounds.height
                )
                rightBounds = CGRect(
                    x: splitX,
                    y: bounds.minY,
                    width: bounds.width * (1 - split.ratio),
                    height: bounds.height
                )
            case .vertical:
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
            }

            var slots: [SplitTree.Spatial.Slot] = [.init(node: self, bounds: bounds)]
            slots += split.left.spatialSlots(in: leftBounds)
            slots += split.right.spatialSlots(in: rightBounds)

            return slots
        }
    }
}

// MARK: SplitTree.Spatial

extension SplitTree.Spatial {
    func slots(in direction: Direction, from referenceNode: SplitTree.Node) -> [Slot] {
        guard let refSlot = slots.first(where: { $0.node == referenceNode }) else { return [] }

        func distance(from rect1: CGRect, to rect2: CGRect) -> Double {
            let dx = rect2.minX - rect1.minX
            let dy = rect2.minY - rect1.minY
            return sqrt(dx * dx + dy * dy)
        }

        let result = switch direction {
        case .left:
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxX <= refSlot.bounds.minX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        case .right:
            slots.filter {
                $0.node != referenceNode && $0.bounds.minX >= refSlot.bounds.maxX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        case .up:
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxY <= refSlot.bounds.minY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        case .down:
            slots.filter {
                $0.node != referenceNode && $0.bounds.minY >= refSlot.bounds.maxY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        }

        return result
    }
}

// MARK: SplitTree.Node Protocols

extension SplitTree.Node: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.leaf(leftView), .leaf(rightView)):
            return leftView === rightView
        case let (.split(split1), .split(split2)):
            return split1 == split2
        default:
            return false
        }
    }
}

// MARK: Structural Identity

extension SplitTree.Node {
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    struct StructuralIdentity: Hashable {
        private let node: SplitTree.Node

        init(_ node: SplitTree.Node) {
            self.node = node
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.node.isStructurallyEqual(to: rhs.node)
        }

        func hash(into hasher: inout Hasher) {
            node.hashStructure(into: &hasher)
        }
    }

    fileprivate func isStructurallyEqual(to other: Node) -> Bool {
        switch (self, other) {
        case let (.leaf(view1), .leaf(view2)):
            return view1 === view2
        case let (.split(split1), .split(split2)):
            return split1.direction == split2.direction &&
                split1.left.isStructurallyEqual(to: split2.left) &&
                split1.right.isStructurallyEqual(to: split2.right)
        default:
            return false
        }
    }

    private enum HashKey: UInt8 {
        case leaf = 0
        case split = 1
    }

    fileprivate func hashStructure(into hasher: inout Hasher) {
        switch self {
        case .leaf(let view):
            hasher.combine(HashKey.leaf)
            hasher.combine(ObjectIdentifier(view))
        case .split(let split):
            hasher.combine(HashKey.split)
            hasher.combine(split.direction)
            split.left.hashStructure(into: &hasher)
            split.right.hashStructure(into: &hasher)
        }
    }
}

extension SplitTree {
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    struct StructuralIdentity: Hashable {
        private let root: Node?
        private let zoomed: Node?

        init(_ tree: SplitTree) {
            self.root = tree.root
            self.zoomed = tree.zoomed
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            areNodesStructurallyEqual(lhs.root, rhs.root) &&
                areNodesStructurallyEqual(lhs.zoomed, rhs.zoomed)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(0)
            if let root = root {
                root.hashStructure(into: &hasher)
            }
            hasher.combine(1)
            if let zoomed = zoomed {
                zoomed.hashStructure(into: &hasher)
            }
        }

        private static func areNodesStructurallyEqual(_ lhs: Node?, _ rhs: Node?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (node1?, node2?):
                return node1.isStructurallyEqual(to: node2)
            default:
                return false
            }
        }
    }
}

// MARK: SplitTree Sequence

extension SplitTree: Sequence {
    func makeIterator() -> IndexingIterator<[ViewType]> {
        return (root?.leaves() ?? []).makeIterator()
    }
}

// MARK: Array Helpers

extension Array {
    /// Returns the index before i, with wraparound. Assumes i is a valid index.
    func indexWrapping(before i: Int) -> Int {
        if i == 0 {
            return count - 1
        }
        return i - 1
    }

    /// Returns the index after i, with wraparound. Assumes i is a valid index.
    func indexWrapping(after i: Int) -> Int {
        if i == count - 1 {
            return 0
        }
        return i + 1
    }
}
