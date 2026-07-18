/// Canonical plain text read from one backend terminal viewport.
public struct BackendScreenText: Decodable, Equatable, Sendable {
    public let text: String
}
