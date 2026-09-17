public import Foundation

/// One node in a Herdr tab's pane-layout tree.
///
/// JSON shape matches ``RemoteTmuxLayoutNode`` so plugin fixtures and native
/// code share one contract (`pane` / `horizontal` / `vertical` plus cell rects).
/// Pane ids are Herdr strings (`w2:p34`), not tmux integers.
public struct RemoteHerdrLayoutNode: Hashable, Sendable, Codable {
    /// Width in terminal cells.
    public var width: Int
    /// Height in terminal cells.
    public var height: Int
    /// X offset from the tab origin, in cells.
    public var x: Int
    /// Y offset from the tab origin, in cells.
    public var y: Int
    /// Leaf pane or split children.
    public var content: RemoteHerdrLayoutContent

    /// Creates a layout node.
    public init(width: Int, height: Int, x: Int, y: Int, content: RemoteHerdrLayoutContent) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.x = x
        self.y = y
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, x, y, pane, horizontal, vertical
    }

    public init(from decoder: any Decoder) throws {
        try self.init(
            from: decoder,
            depth: 0,
            maxDepth: NestedTopologyLimits.default.maxLayoutTreeDepth
        )
    }

    private init(from decoder: any Decoder, depth: Int, maxDepth: Int) throws {
        guard depth <= maxDepth else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "layout tree exceeds max depth \(maxDepth)"
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = max(1, try container.decodeIfPresent(Int.self, forKey: .width) ?? 1)
        height = max(1, try container.decodeIfPresent(Int.self, forKey: .height) ?? 1)
        x = try container.decodeIfPresent(Int.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Int.self, forKey: .y) ?? 0
        if let paneID = try container.decodeIfPresent(String.self, forKey: .pane) {
            content = .pane(paneID)
        } else if let paneInt = try container.decodeIfPresent(Int.self, forKey: .pane) {
            content = .pane(String(paneInt))
        } else if container.contains(.horizontal) {
            content = .horizontal(
                try Self.decodeChildren(from: container, forKey: .horizontal, depth: depth, maxDepth: maxDepth)
            )
        } else if container.contains(.vertical) {
            content = .vertical(
                try Self.decodeChildren(from: container, forKey: .vertical, depth: depth, maxDepth: maxDepth)
            )
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "layout node missing pane/horizontal/vertical"
                )
            )
        }
    }

    private static func decodeChildren(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        depth: Int,
        maxDepth: Int
    ) throws -> [RemoteHerdrLayoutNode] {
        var unkeyed = try container.nestedUnkeyedContainer(forKey: key)
        var children: [RemoteHerdrLayoutNode] = []
        while !unkeyed.isAtEnd {
            let childDecoder = try unkeyed.superDecoder()
            children.append(
                try RemoteHerdrLayoutNode(from: childDecoder, depth: depth + 1, maxDepth: maxDepth)
            )
        }
        guard !children.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [key],
                    debugDescription: "layout split requires at least one child"
                )
            )
        }
        return children
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        switch content {
        case let .pane(id):
            try container.encode(id, forKey: .pane)
        case let .horizontal(children):
            try container.encode(children, forKey: .horizontal)
        case let .vertical(children):
            try container.encode(children, forKey: .vertical)
        }
    }

    /// Depth-first left→right leaf ids (tmux ``paneIDsInOrder``).
    public var paneIDsInOrder: [String] {
        switch content {
        case let .pane(id):
            return [id]
        case let .horizontal(children), let .vertical(children):
            return children.flatMap(\.paneIDsInOrder)
        }
    }

    /// Split nesting + pane set, ignoring geometry (tmux structure signature).
    public var structureSignature: String {
        switch content {
        case let .pane(id):
            return "p:\(id)"
        case let .horizontal(children):
            return "h:\(children.map(\.structureSignature).joined(separator: ","))"
        case let .vertical(children):
            return "v:\(children.map(\.structureSignature).joined(separator: ","))"
        }
    }

    /// First-child divider fraction along this split, or nil for a leaf.
    public var firstChildRatio: Double? {
        switch content {
        case .pane:
            return nil
        case let .horizontal(children):
            guard let first = children.first, width > 0 else { return nil }
            return clampedRatio(Double(first.width) / Double(width))
        case let .vertical(children):
            guard let first = children.first, height > 0 else { return nil }
            return clampedRatio(Double(first.height) / Double(height))
        }
    }

    /// Sequential splits to create every non-root leaf (plugin/cmux CLI analogue).
    public var splitSpecs: [RemoteHerdrSplitSpec] {
        var specs: [RemoteHerdrSplitSpec] = []
        collectSplitSpecs(into: &specs)
        return specs
    }

    public func firstLeaf(withPaneID paneID: String) -> RemoteHerdrLayoutNode? {
        switch content {
        case let .pane(id):
            return id == paneID ? self : nil
        case let .horizontal(children), let .vertical(children):
            for child in children {
                if let found = child.firstLeaf(withPaneID: paneID) { return found }
            }
            return nil
        }
    }

    /// Exact-axis flags for ``RemoteHerdrLifecycle.gridMatch``.
    ///
    /// Exact on the split axis of the nearest parent split; fill on the other.
    /// Sole / root panes report both axes exact.
    public func exactAxisFlags(forPaneID paneID: String) -> (exactCols: Bool, exactRows: Bool)? {
        guard firstLeaf(withPaneID: paneID) != nil else { return nil }
        if let flags = exactAxisFlags(forPaneID: paneID, parentIsHorizontal: nil) {
            return flags
        }
        return (true, true)
    }

    private func exactAxisFlags(
        forPaneID paneID: String,
        parentIsHorizontal: Bool?
    ) -> (exactCols: Bool, exactRows: Bool)? {
        switch content {
        case let .pane(id):
            guard id == paneID else { return nil }
            if let parentIsHorizontal {
                return parentIsHorizontal ? (true, false) : (false, true)
            }
            return (true, true)
        case let .horizontal(children):
            for child in children {
                if let flags = child.exactAxisFlags(forPaneID: paneID, parentIsHorizontal: true) {
                    return flags
                }
            }
            return nil
        case let .vertical(children):
            for child in children {
                if let flags = child.exactAxisFlags(forPaneID: paneID, parentIsHorizontal: false) {
                    return flags
                }
            }
            return nil
        }
    }

    private func collectSplitSpecs(into specs: inout [RemoteHerdrSplitSpec]) {
        let children: [RemoteHerdrLayoutNode]
        let direction: RemoteHerdrSplitDirection
        switch content {
        case .pane:
            return
        case let .horizontal(nodes):
            children = nodes
            direction = .right
        case let .vertical(nodes):
            children = nodes
            direction = .down
        }
        guard children.count >= 2 else {
            children.forEach { $0.collectSplitSpecs(into: &specs) }
            return
        }
        var anchor = children[0].paneIDsInOrder.first ?? ""
        children[0].collectSplitSpecs(into: &specs)
        for index in 1 ..< children.count {
            let leaves = children[index].paneIDsInOrder
            guard let first = leaves.first, !anchor.isEmpty else {
                children[index].collectSplitSpecs(into: &specs)
                continue
            }
            specs.append(
                RemoteHerdrSplitSpec(
                    paneID: first,
                    splitFromPaneID: anchor,
                    direction: direction,
                    ratio: index == 1 ? firstChildRatio : nil
                )
            )
            children[index].collectSplitSpecs(into: &specs)
            anchor = first
        }
    }

    private func clampedRatio(_ value: Double) -> Double {
        min(0.95, max(0.05, value))
    }
}

/// Leaf pane or n-ary split.
public enum RemoteHerdrLayoutContent: Hashable, Sendable {
    /// A Herdr pane id.
    case pane(String)
    /// Children left → right (cmux split ``right``).
    case horizontal([RemoteHerdrLayoutNode])
    /// Children top → bottom (cmux split ``down``).
    case vertical([RemoteHerdrLayoutNode])
}

/// One sequential split needed to realize a layout tree.
public struct RemoteHerdrSplitSpec: Hashable, Sendable {
    /// Pane created by this split.
    public var paneID: String
    /// Existing pane to split from.
    public var splitFromPaneID: String
    /// Split direction.
    public var direction: RemoteHerdrSplitDirection
    /// Optional first-child ratio.
    public var ratio: Double?

    public init(
        paneID: String,
        splitFromPaneID: String,
        direction: RemoteHerdrSplitDirection,
        ratio: Double?
    ) {
        self.paneID = paneID
        self.splitFromPaneID = splitFromPaneID
        self.direction = direction
        self.ratio = ratio
    }
}

/// Layout payload keyed by Herdr tab id (`session.snapshot.layouts` list form).
public struct RemoteHerdrTabLayout: Hashable, Sendable, Codable {
    /// Herdr tab id.
    public var tabID: String
    /// Pane tree for that tab.
    public var layout: RemoteHerdrLayoutNode

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case layout
    }

    /// Creates a named tab layout.
    public init(tabID: String, layout: RemoteHerdrLayoutNode) {
        self.tabID = tabID
        self.layout = layout
    }
}

/// cmux/Herdr split direction (tmux horizontal vs vertical).
public enum RemoteHerdrSplitDirection: String, Hashable, Sendable, Codable {
    /// Split to the right (horizontal children).
    case right
    /// Split downward (vertical children).
    case down
}
