import AppKit
import CmuxNotifications

/// Filters notification hooks down to the ones whose trust descriptor is already
/// trusted, plus the ones the user authorizes interactively, gating each untrusted
/// hook through `CmuxConfigExecutor.authorizeProjectAutomationIfNeeded`.
///
/// The trust store is constructor-injected rather than reached through a global
/// singleton, so the trust source is explicit at the call site (the app composes
/// it with `CmuxActionTrust.shared`).
@MainActor
struct NotificationPolicyHookAuthorizer {
    private let trust: CmuxActionTrust

    init(trust: CmuxActionTrust) {
        self.trust = trust
    }

    func authorize(
        _ hooks: [CmuxResolvedNotificationHook],
        globalConfigPath: String?,
        presentingWindow: NSWindow? = nil
    ) async -> [CmuxResolvedNotificationHook] {
        var authorizedHooks: [CmuxResolvedNotificationHook] = []
        let resolvedPresentingWindow = presentingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow

        for hook in hooks {
            guard let descriptor = hook.trustDescriptor else {
                authorizedHooks.append(hook)
                continue
            }
            guard !trust.isTrusted(descriptor) else {
                authorizedHooks.append(hook)
                continue
            }
            guard let globalConfigPath else {
                continue
            }

            let isAuthorized = await authorizeHook(
                hook,
                descriptor: descriptor,
                globalConfigPath: globalConfigPath,
                presentingWindow: resolvedPresentingWindow
            )
            if isAuthorized {
                authorizedHooks.append(hook)
            }
        }

        return authorizedHooks
    }

    private func authorizeHook(
        _ hook: CmuxResolvedNotificationHook,
        descriptor: CmuxActionTrustDescriptor,
        globalConfigPath: String,
        presentingWindow: NSWindow?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            CmuxConfigExecutor.authorizeProjectAutomationIfNeeded(
                descriptor: descriptor,
                confirm: false,
                configSourcePath: hook.sourcePath,
                globalConfigPath: globalConfigPath,
                displayCommand: "[\(hook.id)] \(hook.command)",
                presentingWindow: presentingWindow
            ) {
                continuation.resume(returning: true)
            } onDenied: {
                continuation.resume(returning: false)
            }
        }
    }
}
