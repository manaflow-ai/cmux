import CmuxBrowser
import Foundation
import Security

struct BrowserWebExtensionCodeSignatureVerifier: Sendable {
    struct VerifiedIdentity: Sendable {
        let identity: BrowserWebExtensionSafariAppIdentity
        let containingAppURL: URL
        let extensionURL: URL
    }

    private let catalog: BrowserWebExtensionCatalog

    init(catalog: BrowserWebExtensionCatalog = .production) {
        self.catalog = catalog
    }

    func verifySafariExtension(at extensionURL: URL) throws -> VerifiedIdentity {
        let standardizedExtensionURL = extensionURL.standardizedFileURL
        let containingAppURL = standardizedExtensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard containingAppURL.pathExtension.lowercased() == "app",
              let appBundle = Bundle(url: containingAppURL),
              let appBundleIdentifier = appBundle.bundleIdentifier,
              let extensionBundle = Bundle(url: standardizedExtensionURL),
              let extensionBundleIdentifier = extensionBundle.bundleIdentifier,
              let identity = catalog.safariAppIdentities.first(where: {
                  $0.appBundleIdentifier == appBundleIdentifier
                      && $0.extensionBundleIdentifier == extensionBundleIdentifier
              }) else {
            throw BrowserWebExtensionCodeSignatureError.untrustedIdentity
        }
        try verifySafariExtensionPoint(at: standardizedExtensionURL)
        try verifyCode(
            at: containingAppURL,
            bundleIdentifier: identity.appBundleIdentifier,
            teamIdentifier: identity.teamIdentifier
        )
        try verifyCode(
            at: standardizedExtensionURL,
            bundleIdentifier: identity.extensionBundleIdentifier,
            teamIdentifier: identity.teamIdentifier
        )
        return VerifiedIdentity(
            identity: identity,
            containingAppURL: containingAppURL,
            extensionURL: standardizedExtensionURL
        )
    }

    func verifyApplication(at appURL: URL) throws -> VerifiedIdentity {
        let standardizedAppURL = appURL.standardizedFileURL
        guard let appBundle = Bundle(url: standardizedAppURL),
              let appBundleIdentifier = appBundle.bundleIdentifier,
              let identity = catalog.safariAppIdentities.first(where: {
                  $0.appBundleIdentifier == appBundleIdentifier
              }) else {
            throw BrowserWebExtensionCodeSignatureError.untrustedIdentity
        }
        let pluginsURL = standardizedAppURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { candidate in
            candidate.pathExtension.lowercased() == "appex"
                && Bundle(url: candidate)?.bundleIdentifier == identity.extensionBundleIdentifier
        }
        guard candidates.count == 1, let extensionURL = candidates.first else {
            throw BrowserWebExtensionCodeSignatureError.untrustedIdentity
        }
        try verifySafariExtensionPoint(at: extensionURL)
        try verifyCode(
            at: standardizedAppURL,
            bundleIdentifier: identity.appBundleIdentifier,
            teamIdentifier: identity.teamIdentifier
        )
        try verifyCode(
            at: extensionURL,
            bundleIdentifier: identity.extensionBundleIdentifier,
            teamIdentifier: identity.teamIdentifier
        )
        return VerifiedIdentity(
            identity: identity,
            containingAppURL: standardizedAppURL,
            extensionURL: extensionURL
        )
    }

    private func verifySafariExtensionPoint(at extensionURL: URL) throws {
        guard let bundle = Bundle(url: extensionURL),
              let extensionPoint = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
              extensionPoint["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension",
              FileManager.default.fileExists(
                atPath: extensionURL.appendingPathComponent("Contents/Resources/manifest.json").path
              ) else {
            throw BrowserWebExtensionCodeSignatureError.untrustedIdentity
        }
    }

    private func verifyCode(
        at url: URL,
        bundleIdentifier: String,
        teamIdentifier: String
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw BrowserWebExtensionCodeSignatureError.invalidSignature
        }
        let requirementText = "anchor apple generic and identifier \"\(bundleIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw BrowserWebExtensionCodeSignatureError.invalidSignature
        }
        let validationFlags = SecCSFlags(
            rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess else {
            throw BrowserWebExtensionCodeSignatureError.invalidSignature
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &signingInformation
        ) == errSecSuccess,
        let signingInformation,
        (signingInformation as NSDictionary)[kSecCodeInfoTeamIdentifier] as? String == teamIdentifier else {
            throw BrowserWebExtensionCodeSignatureError.invalidSignature
        }
    }
}
