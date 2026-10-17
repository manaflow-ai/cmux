/// What a workspace content last laid out: the mapped tree and the daemon's
/// layout capabilities. An equal one applies nothing (perf I3): a store
/// change outside the workspace's layout, or the echo of the window's own
/// gesture, maps to the same tree.
public struct LayoutAppliedTree {
    public private(set) var result: LayoutMapping.Result?
    public private(set) var edgeDocks = false
    public private(set) var rows = false

    public init() {}

    /// Records the tree; true when it differs from the last one.
    public mutating func update(_ result: LayoutMapping.Result, edgeDocks: Bool, rows: Bool) -> Bool {
        defer { (self.result, self.edgeDocks, self.rows) = (result, edgeDocks, rows) }
        return self.result != result || self.edgeDocks != edgeDocks || self.rows != rows
    }
}
