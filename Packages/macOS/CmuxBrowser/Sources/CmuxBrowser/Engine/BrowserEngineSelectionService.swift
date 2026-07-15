public import CmuxCore

/// Resolves stored policy and restored-session intent into a launchable browser engine.
@MainActor
public struct BrowserEngineSelectionService {
    private let applicationProvider: any BrowserApplicationProviding
    private let resolver: BrowserEngineResolver

    /// Creates a browser-engine selection service with injected system boundaries.
    ///
    /// - Parameters:
    ///   - applicationProvider: Supplies LaunchServices handlers and installed browsers.
    ///   - resolver: Maps handler identities to an engine family.
    public init(
        applicationProvider: any BrowserApplicationProviding,
        resolver: BrowserEngineResolver = BrowserEngineResolver()
    ) {
        self.applicationProvider = applicationProvider
        self.resolver = resolver
    }

    /// Selects the effective engine for a newly-created or restored surface.
    ///
    /// A restored engine is authoritative. Otherwise the stored preference is
    /// resolved against the actual LaunchServices HTTP/HTTPS handlers. Explicit
    /// Chromium selection remains Chromium even when no compatible application
    /// is installed, allowing the pane to present an actionable error rather
    /// than silently changing engines.
    ///
    /// - Parameters:
    ///   - preference: The user's stored engine preference.
    ///   - restoredKind: The engine persisted for a restored surface, if any.
    /// - Returns: The effective selection and optional Chromium application.
    public func select(
        preference: BrowserEnginePreference,
        restoredKind: BrowserEngineKind? = nil
    ) -> BrowserEngineSelection {
        let defaultApplications = applicationProvider.defaultBrowserApplications()
        let kind = restoredKind ?? resolver.resolve(
            preference: preference,
            defaultHandlerBundleIdentifiers: defaultApplications.map(\.bundleIdentifier)
        )
        guard kind == .chromium else { return .webKit }

        let defaultChromium = defaultApplications.first {
            resolver.isChromiumFamilyBundleIdentifier($0.bundleIdentifier)
        }
        let application = defaultChromium ?? applicationProvider.installedChromiumApplications().first
        return BrowserEngineSelection(kind: .chromium, chromiumApplication: application)
    }
}
