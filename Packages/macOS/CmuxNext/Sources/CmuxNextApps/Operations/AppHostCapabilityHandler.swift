/// Owns the operations of the app capability families it advertises.
public nonisolated protocol AppHostCapabilityHandler: Sendable {
    /// Family prefixes before the first dot, such as `coderouter` or `agent_cli`.
    var families: Set<String> { get }

    /// Handles an admitted operation, enforcing its own parameter and origin rules.
    /// - Parameter request: The supervisor- or page-admitted call.
    /// - Returns: The operation result without an app ABI envelope.
    /// - Throws: An app ABI refusal or owner failure, including unsupported ops.
    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON
}
