#if canImport(AppKit)
#if DEBUG

public import CmuxTerminalCore

/// The localized strings the Startup Appearance debug panel renders.
///
/// Every label is resolved app-side with `String(localized:)` against the app
/// bundle and injected, because resolving it inside `CmuxAppKitSupportUI` would
/// bind to the package bundle (which lacks the `debug.startupAppearance.*` keys)
/// and silently return the English default, dropping every non-English (Japanese)
/// translation. The profile display strings (`profileDisplayName`/`profileDetail`)
/// reuse the app-side `GhosttyStartupAppearancePreviewProfile` presentation
/// extension; the mode display string covers the panel-local
/// ``StartupAppearancePreviewMode``.
public struct StartupAppearanceDebugStrings: Sendable {
    /// "Startup Appearance Debug" headline shown at the top of the panel.
    public var headerTitle: String
    /// "Preview" group-box heading.
    public var previewHeading: String
    /// "Startup config" picker label.
    public var startupConfigLabel: String
    /// "Appearance" picker label.
    public var appearanceLabel: String
    /// "Apply Preview" button title.
    public var applyPreviewButton: String
    /// "Restore Real Startup" button title.
    public var restoreRealStartupButton: String
    /// "Selected Config" group-box heading.
    public var selectedConfigHeading: String
    /// "Copy Selected Config" button title.
    public var copySelectedConfigButton: String
    /// Text shown for the selected-config box when the profile loads the real
    /// user config (no synthetic preview contents).
    public var realConfigFallback: String
    /// "Applied" group-box heading.
    public var appliedHeading: String
    /// "Config:" label in the Applied group box.
    public var appliedConfigLabel: String
    /// "Appearance:" label in the Applied group box.
    public var appliedAppearanceLabel: String
    /// The help caption in the Applied group box.
    public var appliedHelp: String

    /// The localized display name for a startup-config preview profile.
    public var profileDisplayName: @Sendable (GhosttyStartupAppearancePreviewProfile) -> String
    /// The localized detail caption for a startup-config preview profile.
    public var profileDetail: @Sendable (GhosttyStartupAppearancePreviewProfile) -> String
    /// The localized display name for a panel-local appearance preview mode.
    public var modeDisplayName: @Sendable (StartupAppearancePreviewMode) -> String

    /// Creates the localized string bundle for the panel.
    public init(
        headerTitle: String,
        previewHeading: String,
        startupConfigLabel: String,
        appearanceLabel: String,
        applyPreviewButton: String,
        restoreRealStartupButton: String,
        selectedConfigHeading: String,
        copySelectedConfigButton: String,
        realConfigFallback: String,
        appliedHeading: String,
        appliedConfigLabel: String,
        appliedAppearanceLabel: String,
        appliedHelp: String,
        profileDisplayName: @escaping @Sendable (GhosttyStartupAppearancePreviewProfile) -> String,
        profileDetail: @escaping @Sendable (GhosttyStartupAppearancePreviewProfile) -> String,
        modeDisplayName: @escaping @Sendable (StartupAppearancePreviewMode) -> String
    ) {
        self.headerTitle = headerTitle
        self.previewHeading = previewHeading
        self.startupConfigLabel = startupConfigLabel
        self.appearanceLabel = appearanceLabel
        self.applyPreviewButton = applyPreviewButton
        self.restoreRealStartupButton = restoreRealStartupButton
        self.selectedConfigHeading = selectedConfigHeading
        self.copySelectedConfigButton = copySelectedConfigButton
        self.realConfigFallback = realConfigFallback
        self.appliedHeading = appliedHeading
        self.appliedConfigLabel = appliedConfigLabel
        self.appliedAppearanceLabel = appliedAppearanceLabel
        self.appliedHelp = appliedHelp
        self.profileDisplayName = profileDisplayName
        self.profileDetail = profileDetail
        self.modeDisplayName = modeDisplayName
    }
}

#endif
#endif
