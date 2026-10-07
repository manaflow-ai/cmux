/// One DevTools `Input.*` command.
public struct CDPCall: Hashable, Sendable {
    public var method: String
    public var params: [String: CDPValue]

    public init(method: String, params: [String: CDPValue]) {
        self.method = method
        self.params = params
    }

    /// The params as the engine's DevTools API takes them.
    public var foundationParams: [String: any Sendable] {
        params.mapValues(\.foundation)
    }
}
