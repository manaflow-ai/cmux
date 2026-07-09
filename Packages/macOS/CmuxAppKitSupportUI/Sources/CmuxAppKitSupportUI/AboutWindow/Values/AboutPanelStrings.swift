#if canImport(AppKit)

/// The localized, user-facing strings rendered by the About panel and the
/// Acknowledgments (Third-Party Licenses) window.
///
/// These strings are resolved by the app target against its own bundle and
/// injected into the package views. Resolving them app-side is deliberate: a
/// package calling `String(localized:)` binds to the *package* bundle, which
/// holds none of the `about.*` catalog entries, so every non-English
/// localization (the 19 languages cmux ships) would silently fall back to the
/// English `defaultValue`. Passing the already-resolved values keeps the About
/// window byte-identical in every locale after the move.
public struct AboutPanelStrings: Sendable, Equatable {
    /// Application name shown beneath the icon (`about.appName`).
    public let appName: String
    /// One-line product description (`about.description`).
    public let description: String
    /// Label for the version property row (`about.version`).
    public let versionLabel: String
    /// Label for the build property row (`about.build`).
    public let buildLabel: String
    /// Label for the commit property row (`about.commit`).
    public let commitLabel: String
    /// Title of the Docs button (`about.docs`).
    public let docs: String
    /// Title of the GitHub button (`about.github`).
    public let github: String
    /// Title of the Licenses button (`about.licenses`).
    public let licenses: String

    /// Creates the About panel string bundle.
    public init(
        appName: String,
        description: String,
        versionLabel: String,
        buildLabel: String,
        commitLabel: String,
        docs: String,
        github: String,
        licenses: String
    ) {
        self.appName = appName
        self.description = description
        self.versionLabel = versionLabel
        self.buildLabel = buildLabel
        self.commitLabel = commitLabel
        self.docs = docs
        self.github = github
        self.licenses = licenses
    }
}

/// The localized strings rendered by the Acknowledgments (Third-Party Licenses)
/// window.
///
/// Resolved app-side for the same bundle-localization reason documented on
/// ``AboutPanelStrings``.
public struct AcknowledgmentsStrings: Sendable, Equatable {
    /// The Acknowledgments window's title (`about.licenses.windowTitle`).
    public let windowTitle: String
    /// Body text shown when the bundled licenses file cannot be read
    /// (`about.licenses.notFound`).
    public let notFound: String

    /// Creates the Acknowledgments string bundle.
    public init(windowTitle: String, notFound: String) {
        self.windowTitle = windowTitle
        self.notFound = notFound
    }
}

#endif
