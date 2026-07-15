import Foundation

@MainActor
struct RepositoryScriptAuthorizationService: RepositoryScriptAuthorizing {
    func isTrusted(_ descriptor: CmuxActionTrustDescriptor) -> Bool {
        CmuxActionTrust.shared.isTrusted(descriptor)
    }

    @discardableResult
    func authorize(
        descriptor: CmuxActionTrustDescriptor,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String,
        onAuthorized: @escaping () -> Void,
        onDenied: @escaping () -> Void
    ) -> Bool {
        CmuxConfigExecutor.authorizeProjectAutomationIfNeeded(
            descriptor: descriptor,
            confirm: false,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayCommand: displayCommand,
            displayTitle: displayTitle,
            onAuthorized: onAuthorized,
            onDenied: onDenied
        )
    }
}
