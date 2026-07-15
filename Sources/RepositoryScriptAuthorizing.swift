import Foundation

@MainActor
protocol RepositoryScriptAuthorizing {
    func isTrusted(_ descriptor: CmuxActionTrustDescriptor) -> Bool

    @discardableResult
    func authorize(
        descriptor: CmuxActionTrustDescriptor,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String,
        onAuthorized: @escaping () -> Void,
        onDenied: @escaping () -> Void
    ) -> Bool
}
