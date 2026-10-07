import CmuxMobileWire

/// One owner event of `workspace:<host>` before it gets a seq.
public struct WorkspaceChange: Hashable, Sendable {
    public var op: String
    public var params: JSONValue

    public init(op: String, params: JSONValue) {
        self.op = op
        self.params = params
    }
}
