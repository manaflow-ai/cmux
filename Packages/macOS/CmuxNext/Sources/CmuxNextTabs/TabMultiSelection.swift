/// Chrome's tab multi-selection for one strip. Not built yet: every click selects one tab.
public struct TabMultiSelection: Hashable, Sendable {
    public private(set) var ids: Set<TabID> = []
    public private(set) var anchor: TabID?

    public init() {}

    public enum Click: Hashable, Sendable { case plain, toggle, range, addRange }

    public var isMultiple: Bool { ids.count > 1 }

    public func contains(_ id: TabID) -> Bool { ids.contains(id) }

    public func ordered(in order: [TabID], active: TabID?) -> [TabID] { active.map { [$0] } ?? [] }

    public mutating func click(_ id: TabID, _ click: Click, order: [TabID], active: TabID?) -> TabID? { id }

    public mutating func clear() { ids = [] }
}

/// Moving a multi-selection. Not built yet: the order stays.
public struct TabSelectionMove: Hashable, Sendable {
    public var order: [TabID]
    public var pinned: Set<TabID>

    public init(order: [TabID], pinned: Set<TabID>) {
        self.order = order
        self.pinned = pinned
    }

    public func moving(_ selection: Set<TabID>, to index: Int) -> [TabID] { order }

    public static func nextStep(from current: [TabID], toward target: [TabID]) -> (id: TabID, index: Int)? { nil }
}
