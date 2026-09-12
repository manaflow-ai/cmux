import CMUXMobileCore
import CmuxAuthRuntime
import CmuxGit
import CmuxIrohTransport
import CmuxMobileTransport
import CmuxSettings
import CmuxTerminalCore
import CryptoKit
import Foundation
import OSLog
import StackAuth
import os

extension MobileHostService {
    nonisolated private static let terminalThemeRevisionEpoch = UUID().uuidString
    /// The single shape every public `mobile.host.status` reply uses (the
    /// public-status cache, the network status gate, and
    /// `TerminalController`'s no-private-metadata branch), so the fields
    /// cannot drift. Identity-free status carries no routes: a caller already
    /// reached the Mac to ask for status, while route discovery belongs to the
    /// authenticated registry. The Mac's account and cryptographic identities
    /// are never on this unauthenticated surface.
    nonisolated static func publicStatusPayload(routes: [CmxAttachRoute], now: Date = Date()) -> [String: Any] {
        // The Mac's resolved terminal theme is caller-independent, so it rides
        // the public payload (identity merges on top). `GhosttyConfig.loadForCmux()`
        // resolves named Ghostty themes, Ghostty's built-in defaults or cmux's
        // managed fresh-config defaults, and explicit color settings into a complete
        // effective palette; the phone applies it so its embedded terminal
        // renders with the Mac's colors instead of the built-in Monokai default.
        let theme = TerminalTheme(ghosttyConfig: GhosttyConfig.loadForCmux())
        return [
            "routes": routes.mobileHostJSONObjects(for: .publicStatus, at: now),
            "terminal_fidelity": "render_grid",
            "capabilities": mobileHostCapabilities,
            "theme": theme.mobileHostJSONObject,
        ]
    }
    /// `publicStatusPayload` plus the Mac's identity, for a caller that has
    /// proven same-account Stack ownership. The pairing QR no longer carries
    /// the display name or the device id, so this reply is where a freshly
    /// paired phone learns what to call this Mac, which paired-Mac record owns
    /// the connection, and which app instance owns its routes.
    nonisolated static func identityStatusPayload(
        routes: [CmxAttachRoute],
        additionalCapabilities: Set<String> = [],
        phonePushDefaults: UserDefaults = .standard,
        phonePushAdmission: PhonePushAdmission = .unknown,
        phonePushQueuePersistenceStatus: PhonePushQueuePersistenceStatus =
            .unknown,
        phonePushAPIBaseURL: URL = AuthEnvironment.vmAPIBaseURL,
        now: Date = Date()
    ) -> [String: Any] {
        var payload = publicStatusPayload(routes: [], now: now)
        let legacyCompatibleRoutes = routes.filter { $0.kind != .nextTransport }
        payload["routes"] = legacyCompatibleRoutes.mobileHostJSONObjects(
            for: .authenticated,
            at: now
        )
        // Additive field for clients that understand the graduation route. It
        // deliberately stays out of `routes`: older Codable clients reject an
        // unknown enum case for the entire array rather than dropping one item.
        if let nextRoute = MobileHostPublicStatusCache.nextTransportSnapshot(),
            let encodedNextRoute = [nextRoute]
                .mobileHostJSONObjects(for: .authenticated, at: now)
                .first
        {
            payload["next_transport_route"] = encodedNextRoute
        }
        payload["capabilities"] = applyingDebugCapabilitySuppressions(
            mobileHostCapabilities
                + additionalCapabilities
                    .union([
                        phonePushStatusCapability,
                        phonePushSettingsCapability,
                        phonePushTestCapability,
                    ])
                    .sorted()
        )
        payload["terminal_theme_revision_epoch"] = terminalThemeRevisionEpoch
        payload["mac_device_id"] = MobileHostIdentity.deviceID()
        payload["mac_instance_tag"] = MobileHostIdentity.instanceTag()
        if let clientNamespace = CmxIrohMacBundleNamespace(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )?.rawValue {
            payload["mac_client_namespace"] = clientNamespace
        }
        // The sibling-tag grant set for development phones. Only this Mac's
        // exact-tag phone adopts it (the phone ignores the field from any
        // other reporter), so advertising it unconditionally is safe.
        payload["mac_compatible_mac_tags"] = MobileCompatibleMacTags.tags(
            in: phonePushDefaults
        )
        payload["phone_push"] = [
            "forwarding_enabled": PhonePushConfiguration.forwardingEnabled(
                in: phonePushDefaults
            ),
            "mode": PhoneForwardingMode.fromDefaults(phonePushDefaults).rawValue,
            "admission": phonePushAdmission.rawValue,
            "queue_persistence": phonePushQueuePersistenceStatus.rawValue,
            "hide_content": phonePushDefaults.bool(
                forKey: PhonePushSettings.hideContentKey
            ),
            "api_origin": canonicalPhonePushAPIBaseURL(phonePushAPIBaseURL),
            // Reaching this payload means `verifiedStackCaller` already proved
            // the presented token belongs to the Mac's current Stack account.
            "account_scope": "verified_same_account",
        ]
        if let displayName = MobileHostIdentity.instanceDisplayName() {
            payload["mac_display_name"] = displayName
        }
        let build = MobileHostBuildIdentity.current()
        if let appVersion = build.appVersion {
            payload["mac_app_version"] = appVersion
        }
        if let appBuild = build.appBuild {
            payload["mac_app_build"] = appBuild
        }
        return payload
    }

    nonisolated private static func canonicalPhonePushAPIBaseURL(_ url: URL) -> String {
        var value = url.absoluteString
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

}
