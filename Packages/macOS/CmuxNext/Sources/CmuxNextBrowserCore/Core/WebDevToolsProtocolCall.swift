/// One DevTools protocol call: a method and its parameters, as
/// ``CEFTab/devTools(method:params:)`` sends it.
public nonisolated struct WebDevToolsProtocolCall: Sendable {
    /// The protocol method (`Network.setCacheDisabled`).
    public var method: String
    /// The method's parameters (JSON values).
    public var params: [String: any Sendable]

    /// - Parameters:
    ///   - method: The protocol method.
    ///   - params: Its parameters; empty for none.
    public init(_ method: String, _ params: [String: any Sendable] = [:]) {
        self.method = method
        self.params = params
    }
}
