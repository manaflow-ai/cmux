/// Performs the on-disk account switch by invoking the `sr` CLI.
///
/// The daemon has no switch endpoint: `sr switch <email>` (Codex) and
/// `sr claude switch <profile>` (Claude) rewrite the local auth files, after
/// which the caller POSTs `/_subrouter/reload-accounts`. This seam isolates
/// the subprocess so tests inject a fake and the store owns the sequencing.
public protocol SubrouterAccountSwitching: Sendable {
    /// Switches the provider's active account.
    ///
    /// - Parameters:
    ///   - provider: The provider to switch (Codex or Claude).
    ///   - accountID: The daemon account id (Codex email / Claude profile).
    ///   - commandPath: An explicit `sr` binary path, or `nil` to resolve
    ///     from `PATH` and the standard install locations.
    /// - Throws: ``SubrouterSwitchError`` describing the failure.
    func switchAccount(
        provider: SubrouterProvider,
        accountID: String,
        commandPath: String?
    ) async throws
}
