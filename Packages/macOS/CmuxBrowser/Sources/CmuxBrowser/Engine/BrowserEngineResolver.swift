public import CmuxCore
import Foundation

/// Resolves a browser-engine preference against LaunchServices handler identities.
public struct BrowserEngineResolver: Sendable {
    /// Creates an engine resolver.
    public init() {}

    /// Resolves the effective engine.
    ///
    /// Handler identifiers should be ordered by preference, normally HTTPS then
    /// HTTP. Explicit preferences do not inspect the handlers. Automatic mode
    /// selects Chromium only for a known Chromium-family bundle identifier;
    /// Safari, Firefox-family handlers, and unknown applications use WebKit.
    ///
    /// - Parameters:
    ///   - preference: The stored user preference.
    ///   - defaultHandlerBundleIdentifiers: Bundle identifiers returned by
    ///     LaunchServices for representative HTTPS and HTTP URLs.
    /// - Returns: The engine to use for a new browser surface.
    public func resolve(
        preference: BrowserEnginePreference,
        defaultHandlerBundleIdentifiers: [String]
    ) -> BrowserEngineKind {
        switch preference {
        case .webKit:
            return .webKit
        case .chromium:
            return .chromium
        case .automatic:
            guard let preferredHandler = defaultHandlerBundleIdentifiers.first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return .webKit
            }
            return isChromiumFamilyBundleIdentifier(preferredHandler)
                ? .chromium
                : .webKit
        }
    }

    /// Returns whether a LaunchServices handler identity belongs to a supported
    /// Chromium-family application.
    ///
    /// - Parameter bundleIdentifier: An application bundle identifier.
    /// - Returns: `true` for Chromium-family applications cmux can drive.
    public func isChromiumFamilyBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if BrowserImportBrowserDescriptor.allBrowserDescriptors.contains(where: { descriptor in
            descriptor.family == .chromium && descriptor.bundleIdentifiers.contains {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }
        }) {
            return true
        }

        return Self.chromiumBundleIdentifierPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static let chromiumBundleIdentifierPrefixes = [
        "com.google.chrome",
        "com.brave.browser",
        "com.microsoft.edge",
        "com.microsoft.edgemac",
        "com.operasoftware.",
        "com.vivaldi.vivaldi",
        "company.thebrowser.",
        "org.chromium.",
    ]
}
