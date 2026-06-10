import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Generic agent hook notification dedupe
extension CMUXCLI {
    func notificationDedupeFingerprint(status: AgentHookNotificationStatus?, ctx: GenericAgentHookContext) -> String? {
        guard (ctx.def.name == "grok" || ctx.def.name == "antigravity"), !ctx.sessionId.isEmpty, status == .idle else {
            return nil
        }
        return "idle-turn"
    }

    func hasActiveAntigravityBackgroundWork(ctx: GenericAgentHookContext) -> Bool {
        ctx.def.name == "antigravity" && (ctx.input.rawObject?["fullyIdle"] as? Bool) == false
    }

    func shouldSendNotification(fingerprint: String?, ctx: GenericAgentHookContext) -> Bool {
        guard let fingerprint else { return true }
        return (try? ctx.store.recentlyEmittedNotification(sessionId: ctx.sessionId, fingerprint: fingerprint)) != true
    }

    func markNotificationSent(fingerprint: String?, ctx: GenericAgentHookContext) {
        guard let fingerprint else { return }
        try? ctx.store.markNotificationEmitted(sessionId: ctx.sessionId, fingerprint: fingerprint)
    }
}
