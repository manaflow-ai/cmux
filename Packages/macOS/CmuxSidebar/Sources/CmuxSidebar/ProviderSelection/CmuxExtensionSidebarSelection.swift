public import AppKit
import CmuxExtensionSidebarExamples
import CmuxFoundation
import CmuxSettings
public import CmuxSidebarProviderKit

/// Resolves the persisted sidebar-provider selection to the set of provider
/// descriptors offered in the switcher menu and command palette, and renders the
/// right-click switcher menu.
///
/// This is the single definition of which sidebar views exist (the default
/// workspaces view, the bundled preset providers, the hosted extension sidebar,
/// and beta custom sidebars), how a persisted selection maps to a rendered view
/// under the experimental feature gates, and how the persisted selection is
/// written. AppKit/static call sites that run outside the SwiftUI update cycle
/// (the switcher menu, the command-palette builder, the extensions-browser
/// opener) construct an instance and read it directly; SwiftUI views bind
/// reactively to the same catalog keys.
///
/// The backing `UserDefaults` suite is constructor-injected so the resolver is
/// testable against a scoped suite and carries no static runtime state. Call
/// sites that operate on the user's live selection construct
/// `CmuxExtensionSidebarSelection()`, which defaults to `.standard` — the same
/// suite and keys the settings store persists to.
public struct CmuxExtensionSidebarSelection {
    /// `UserDefaults` key the persisted provider selection is stored under.
    public static let defaultsKey = "cmuxExtensionSidebar.providerId"
    /// `UserDefaults` key the last-selected hosted-extension name is stored under.
    public static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"
    /// Provider id of the always-available default workspaces sidebar.
    public static let defaultProviderId = CmuxSidebarProviderDescriptor.defaultWorkspacesID
    /// Provider id of the hosted-extension sidebar (experimental Extensions beta).
    public static let hostedExtensionsProviderId = "cmux.sidebar.extensions"
    /// Provider-id prefix for user/agent-authored custom sidebars. The
    /// suffix after the prefix is the sidebar's file base name.
    public static let customSidebarProviderPrefix = "cmux.sidebar.custom."

    /// The `UserDefaults` suite the persisted selection and feature flags are
    /// read from and written to.
    private let defaults: UserDefaults

    /// Creates a resolver reading/writing the given `UserDefaults` suite.
    /// Defaults to `.standard`, the live suite the settings store persists to.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Synchronous read of the experimental Extensions flag for the on-demand
    /// AppKit/static paths (the toggle menu, the command-palette builder, the
    /// extensions-browser opener) that have no `SettingsRuntime` in scope and
    /// run outside the SwiftUI update cycle.
    ///
    /// SwiftUI views bind reactively via `@LiveSetting(\.betaFeatures.extensions)`.
    /// This synchronous read resolves the same catalog key
    /// (`BetaFeaturesCatalogSection.extensions`) against `UserDefaults`, which is
    /// the same suite and key the store persists to, so the catalog stays the
    /// single definition of the key, decode, and default.
    public var isEnabled: Bool {
        // Read the single beta-features section, not the whole `SettingCatalog`.
        // Constructing the full catalog allocates ~20 sub-sections (including
        // `AutomationCatalogSection`/`SecretFileKey`) just to reach one flag;
        // doing that on the SwiftUI body's hot path turned the sidebar
        // re-render into a CPU catastrophe (issue #5970).
        let key = BetaFeaturesCatalogSection().extensions
        return Bool.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// The bundled preset providers (Project Worktrees, Attention Queue, Dev
    /// Servers, Last Prompt, Super Compact, Browser Stack).
    public var providers: [any CmuxSidebarProvider] {
        SidebarExamples.providers
    }

    // MARK: - Custom sidebars (beta)

    /// Synchronous read of the experimental custom-sidebars flag, mirroring
    /// ``isEnabled`` for the AppKit/static paths (the picker menu).
    public var customSidebarsEnabled: Bool {
        // See ``isEnabled``: read only the beta-features section so a body-path
        // access does not allocate the entire `SettingCatalog` (issue #5970).
        let key = BetaFeaturesCatalogSection().customSidebars
        return Bool.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    public var customSidebarsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.json` file in the
    /// sidebars directory (`.swift` preferred when both exist), titled by the
    /// file's base name.
    public var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if extensionByName[name] == "swift" { continue }
            extensionByName[name] = ext
        }
        return extensionByName.keys.sorted().map { name in
            CmuxSidebarProviderDescriptor(
                id: Self.customSidebarProviderPrefix + name,
                title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.custom.\(name)", defaultValue: name),
                subtitle: CmuxSidebarProviderLocalizedText(
                    key: "sidebar.provider.custom.subtitle",
                    defaultValue: String(localized: "sidebar.provider.custom.subtitle", defaultValue: "Custom sidebar")
                ),
                systemImageName: "wand.and.stars",
                isHostProvided: false
            )
        }
    }

    /// Resolves a custom-sidebar provider id to its backing file URL
    /// (`.swift` preferred), or `nil` if neither file exists.
    public func customSidebarFileURL(forProviderId providerId: String) -> URL? {
        customSidebarFileURL(forProviderId: providerId, sidebarsDirectory: customSidebarsDirectory)
    }

    /// Resolves a custom-sidebar provider id to its backing file URL within an
    /// explicit sidebars directory (`.swift` preferred), or `nil` if neither
    /// file exists.
    public func customSidebarFileURL(forProviderId providerId: String, sidebarsDirectory: URL) -> URL? {
        guard providerId.hasPrefix(Self.customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(Self.customSidebarProviderPrefix.count))
        guard Self.isValidCustomSidebarFileBaseName(name) else { return nil }
        let swiftURL = sidebarsDirectory.appendingPathComponent("\(name).swift", isDirectory: false)
        if FileManager.default.fileExists(atPath: swiftURL.path) { return swiftURL }
        let jsonURL = sidebarsDirectory.appendingPathComponent("\(name).json", isDirectory: false)
        if FileManager.default.fileExists(atPath: jsonURL.path) { return jsonURL }
        return nil
    }

    private static func isValidCustomSidebarFileBaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name == (name as NSString).lastPathComponent
    }

    /// The always-available built-in views: the default workspaces sidebar plus
    /// the bundled preset providers (Project Worktrees, Attention Queue, Dev
    /// Servers, Last Prompt, Super Compact, Browser Stack). These ship
    /// independently of the experimental Extensions feature, so they stay in
    /// the switcher menu regardless of the beta flag.
    public var builtInDescriptors: [CmuxSidebarProviderDescriptor] {
        [.defaultWorkspaces] + providers.map { $0.descriptor }
    }

    /// Descriptors offered in the switcher menu and command palette. The hosted
    /// extension entry belongs to the experimental Extensions feature, so it is
    /// only offered while that beta is enabled; the built-in views are always
    /// offered.
    public var descriptors: [CmuxSidebarProviderDescriptor] {
        var result = isEnabled ? builtInDescriptors + [hostedExtensionsDescriptor] : builtInDescriptors
        if customSidebarsEnabled { result += customSidebarDescriptors }
        return result
    }

    /// Every descriptor that can ever be selected, ignoring feature gates. Used
    /// to register command-palette handlers so a runtime flag flip always has a
    /// handler to invoke; what is *shown* uses ``descriptors``.
    public var allDescriptors: [CmuxSidebarProviderDescriptor] {
        builtInDescriptors + [hostedExtensionsDescriptor] + customSidebarDescriptors
    }

    /// Descriptor for the hosted-extension sidebar, titled by the last-selected
    /// extension name when one is persisted.
    public var hostedExtensionsDescriptor: CmuxSidebarProviderDescriptor {
        let selectedName = defaults.string(forKey: Self.selectedExtensionNameDefaultsKey)?.nilIfEmpty
        return CmuxSidebarProviderDescriptor(
            id: Self.hostedExtensionsProviderId,
            title: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.title",
                defaultValue: selectedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar")
            ),
            subtitle: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.subtitle",
                defaultValue: selectedName == nil
                    ? String(localized: "sidebar.provider.extensions.subtitle", defaultValue: "Custom sidebar")
                    : String(localized: "sidebar.provider.extensions.selectedSubtitle", defaultValue: "Sidebar extension")
            ),
            systemImageName: "puzzlepiece.extension",
            isHostProvided: true
        )
    }

    /// The descriptor matching a provider id, falling back to the default
    /// workspaces descriptor for an unknown id.
    public func descriptor(for providerId: String) -> CmuxSidebarProviderDescriptor {
        descriptors.first { $0.id == providerId } ?? .defaultWorkspaces
    }

    /// Whether an already-`effectiveProviderId`-resolved selection renders the
    /// built-in default workspaces sidebar. This mirrors
    /// `descriptor(for:).id == defaultWorkspacesID` exactly for an effective id,
    /// but WITHOUT building the full ``descriptors`` list — which constructs a
    /// `SettingCatalog` twice (via ``isEnabled``/``customSidebarsEnabled``) and
    /// enumerates the custom-sidebars directory. Those are far too expensive to
    /// run on every SwiftUI body pass; doing so was the multiplier behind the
    /// ~100% CPU re-render loop in issue #5970. Only cheap static lookups and at
    /// most two `fileExists` probes run here, so it is safe for the body.
    ///
    /// The input must be ``effectiveProviderId(_:extensionsEnabled:)``'s output:
    /// that already routes a hosted/custom selection back to the default sidebar
    /// while its feature gate is off, so this only needs to confirm the resolved
    /// id maps to a renderable non-default view.
    public func resolvesToDefaultSidebar(effectiveProviderId id: String) -> Bool {
        if id == Self.defaultProviderId { return true }
        if id == Self.hostedExtensionsProviderId { return false }
        if id.hasPrefix(Self.customSidebarProviderPrefix) {
            // A custom selection survives only while its backing file exists;
            // otherwise the descriptor lookup falls back to the default sidebar.
            return customSidebarFileURL(forProviderId: id) == nil
        }
        // Bundled preset providers are always registered regardless of any beta
        // flag; an unknown/stale id has no provider and falls back to default.
        return provider(for: id) == nil
    }

    /// The bundled preset provider matching a provider id, or `nil`.
    public func provider(for providerId: String) -> (any CmuxSidebarProvider)? {
        providers.first { $0.descriptor.id == providerId }
    }

    /// Resolves the persisted provider selection to the provider that is
    /// actually rendered. The hosted-extensions provider is part of the
    /// experimental Extensions feature, so a persisted hosted selection falls
    /// back to the default workspaces sidebar while the beta is disabled,
    /// otherwise turning the feature off would strand the user on an empty
    /// sidebar with no switcher entry to escape it. Built-in views are always
    /// honored, so the switcher and its active-view checkmark keep working
    /// regardless of the beta flag.
    public func effectiveProviderId(_ persistedProviderId: String, extensionsEnabled: Bool) -> String {
        if persistedProviderId == Self.hostedExtensionsProviderId, !extensionsEnabled {
            return Self.defaultProviderId
        }
        return persistedProviderId
    }

    /// The localized switcher-menu title for a descriptor.
    public func localizedTitle(for descriptor: CmuxSidebarProviderDescriptor) -> String {
        localizedText(descriptor.title)
    }

    /// Resolves a provider's localized text against the main bundle's
    /// `Localizable` table, falling back to its default value.
    public func localizedText(_ text: CmuxSidebarProviderLocalizedText) -> String {
        NSLocalizedString(
            text.key,
            tableName: "Localizable",
            bundle: .main,
            value: text.defaultValue,
            comment: ""
        )
    }

    /// Persists the selected provider id to this resolver's `UserDefaults` suite.
    public func setProviderId(_ providerId: String) {
        defaults.set(providerId, forKey: Self.defaultsKey)
    }

    /// Shows the right-click switcher menu anchored to a view. The menu switches
    /// between the always-available built-in views (and the hosted extension
    /// sidebar when the experimental Extensions beta is enabled, plus any beta
    /// custom sidebars), so it is shown regardless of the flag.
    @MainActor
    public func showMenu(anchorView: NSView, event: NSEvent?) {
        let menu = NSMenu()
        // `popUp(positioning:at:in:)` runs the menu modally and fires the
        // selected item's action before it returns, so a menu target created
        // here lives long enough to receive `selectProvider(_:)`. Retaining it
        // locally (instead of a process-wide `.shared` singleton) keeps the
        // selection writer constructor-injectable and removes static runtime
        // state per the refactor's de-singletonization direction.
        let menuTarget = CmuxExtensionSidebarMenuTarget(selection: self)
        let persistedProviderId = defaults.string(forKey: Self.defaultsKey) ?? Self.defaultProviderId
        let selectedProviderId = descriptor(
            for: effectiveProviderId(persistedProviderId, extensionsEnabled: isEnabled)
        ).id
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: localizedTitle(for: descriptor),
                action: #selector(CmuxExtensionSidebarMenuTarget.selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = descriptor.id
            item.target = menuTarget
            item.state = selectedProviderId == descriptor.id ? .on : .off
            item.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
        // Keep the target alive for the full duration of the modal popUp.
        withExtendedLifetime(menuTarget) {}
    }
}
