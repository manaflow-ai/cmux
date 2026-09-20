/// Loads a credential after the coordinator accepts the handshake key.
public struct MobileRemoteSSHCredentialSource: Sendable {
    private let loader: @Sendable () async throws -> MobileRemoteCredentialMaterial?
    private let responder: @Sendable (MobileRemoteSSHKeyboardChallenge) async throws -> [String]

    /// Creates an injected source without accessing storage.
    /// - Parameter load: Returns material or nil for an interactive/provider auth path.
    public init(
        load: @escaping @Sendable () async throws -> MobileRemoteCredentialMaterial?,
        respondToKeyboardChallenge: @escaping @Sendable (MobileRemoteSSHKeyboardChallenge) async throws -> [String] = { _ in throw MobileRemoteSSHKeyboardError.answerCountMismatch }
    ) {
        loader = load
        responder = respondToKeyboardChallenge
    }

    /// Loads material, withholding a result if cancellation was observed.
    /// - Returns: The requested short-lived credential.
    /// - Throws: Cancellation or storage errors without exposing secret bytes.
    public func load() async throws -> MobileRemoteCredentialMaterial? {
        try Task.checkCancellation()
        let material = try await loader()
        try Task.checkCancellation()
        return material
    }

    /// Collects transient prompt answers without storing them in profile data.
    public func respond(to challenge: MobileRemoteSSHKeyboardChallenge) async throws -> [String] {
        try Task.checkCancellation()
        let answers = try await responder(challenge)
        try Task.checkCancellation()
        guard answers.count == challenge.prompts.count else { throw MobileRemoteSSHKeyboardError.answerCountMismatch }
        return answers
    }
}
