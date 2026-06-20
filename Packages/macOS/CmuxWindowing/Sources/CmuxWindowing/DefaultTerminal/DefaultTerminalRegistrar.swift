public import AppKit
public import UniformTypeIdentifiers

/// Reads and updates whether this app bundle is the default macOS handler for
/// the terminal-shaped LaunchServices targets: the `ssh` URL scheme plus the
/// `com.apple.terminal.shell-script` and `public.unix-executable` content
/// types.
///
/// Lifted from AppDelegate's `DefaultTerminalRegistration`, which was a
/// caseless `enum` namespace of `static` members. CONVENTIONS bans that shape
/// (a static-only utility is a namespace in disguise), so the behavior moved
/// onto this real instance type. The bundle URL, the `NSWorkspace`, and the
/// post-registration change notifier are constructor-injected; the production
/// composition root supplies `Bundle.main.bundleURL`, `NSWorkspace.shared`, and
/// the closure that posts `.defaultTerminalRegistrationDidChange` so the
/// default-terminal Settings/menu UI refreshes.
///
/// The target schemes/content-type identifiers and the matching logic are
/// byte-for-byte the legacy ones; only the receiver changed from the static
/// namespace to this injected instance.
@MainActor
public struct DefaultTerminalRegistrar {
    /// The URL schemes cmux registers as default terminal handler for.
    public static let urlSchemes = ["ssh"]
    /// The content-type identifiers cmux registers as default terminal handler
    /// for.
    public static let contentTypeIdentifiers = [
        "com.apple.terminal.shell-script",
        "public.unix-executable"
    ]

    /// The total number of LaunchServices targets cmux registers for.
    public static var targetCount: Int {
        urlSchemes.count + contentTypeIdentifiers.count
    }

    /// Resolves the `UTType` for a content-type identifier, importing it when
    /// the system does not already know it.
    /// - Parameter identifier: The content-type identifier.
    /// - Returns: The resolved `UTType`.
    public static func contentType(forIdentifier identifier: String) -> UTType {
        UTType(identifier) ?? UTType(importedAs: identifier)
    }

    private let bundleURL: URL
    private let workspace: NSWorkspace
    private let onRegistrationDidChange: @MainActor () -> Void

    /// Creates a registrar.
    /// - Parameters:
    ///   - bundleURL: This app's bundle URL (production: `Bundle.main.bundleURL`).
    ///   - workspace: The `NSWorkspace` used for handler queries and updates
    ///     (production: `.shared`).
    ///   - onRegistrationDidChange: Invoked on the main actor after a
    ///     registration attempt so observers refresh; production posts
    ///     `.defaultTerminalRegistrationDidChange`.
    public init(
        bundleURL: URL,
        workspace: NSWorkspace = .shared,
        onRegistrationDidChange: @escaping @MainActor () -> Void
    ) {
        self.bundleURL = bundleURL
        self.workspace = workspace
        self.onRegistrationDidChange = onRegistrationDidChange
    }

    /// Reports how many of the registered targets currently route to this
    /// bundle.
    /// - Returns: The current ``DefaultTerminalRegistrationStatus``.
    public func currentStatus() -> DefaultTerminalRegistrationStatus {
        let normalizedBundleURL = Self.normalizedApplicationURL(bundleURL)
        let matchedURLSchemes = Self.urlSchemes.filter { scheme in
            guard let url = URL(string: "\(scheme)://cmux-default-terminal-check") else {
                return false
            }
            return Self.normalizedApplicationURL(workspace.urlForApplication(toOpen: url)) == normalizedBundleURL
        }.count

        let matchedContentTypes = Self.contentTypeIdentifiers.filter { identifier in
            let contentType = Self.contentType(forIdentifier: identifier)
            return Self.normalizedApplicationURL(workspace.urlForApplication(toOpen: contentType)) == normalizedBundleURL
        }.count

        return DefaultTerminalRegistrationStatus(
            matchedTargetCount: matchedURLSchemes + matchedContentTypes,
            targetCount: Self.targetCount
        )
    }

    /// Registers this bundle as the default handler for every target,
    /// notifying observers afterward.
    /// - Throws: ``DefaultTerminalRegistrationError`` when LaunchServices
    ///   registration fails.
    public func setAsDefault() async throws {
        let normalizedBundleURL = Self.normalizedApplicationURL(bundleURL) ?? bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var didAttemptHandlerUpdate = false
        defer {
            if didAttemptHandlerUpdate {
                let notify = onRegistrationDidChange
                Task { @MainActor in
                    notify()
                }
            }
        }

        let registerStatus = LSRegisterURL(normalizedBundleURL as CFURL, true)
        guard registerStatus == noErr else {
            throw DefaultTerminalRegistrationError.launchServicesRegistrationFailed(registerStatus)
        }
        didAttemptHandlerUpdate = true

        for scheme in Self.urlSchemes {
            try await workspace.setDefaultApplication(
                at: normalizedBundleURL,
                toOpenURLsWithScheme: scheme
            )
        }

        for identifier in Self.contentTypeIdentifiers {
            let contentType = Self.contentType(forIdentifier: identifier)
            try await workspace.setDefaultApplication(
                at: normalizedBundleURL,
                toOpen: contentType
            )
        }
    }

    private static func normalizedApplicationURL(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
