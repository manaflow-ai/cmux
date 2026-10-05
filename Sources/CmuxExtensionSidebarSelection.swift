import AppKit
import CmuxExtensionSidebarExamples
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
@_spi(CmuxHostTransport) import CmuxSidebar
import CmuxSidebarProviderKit
import Foundation

enum CmuxExtensionSidebarSelection {
    @MainActor
    private static var inMemoryTemplatePreview: (providerId: String, source: String)?

    // No "." in this key: ContentView and VerticalTabsSidebar read it through
    // @AppStorage, and SwiftUI re-evaluated every view holding a dotted
    // @AppStorage key when an unrelated key changed (#13930).
    static let defaultsKey = "cmuxExtensionSidebarProviderId"
    static let legacyDefaultsKey = "cmuxExtensionSidebar.providerId"
    static let selectedExtensionBundleIDDefaultsKey = "cmuxExtensionSidebar.selectedExtensionBundleId"
    static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"
    static let defaultProviderId = CmuxSidebarProviderDescriptor.defaultWorkspacesID
    static let conversationSidebarProviderId = "cmux.sidebar.conversations"
    static let hostedExtensionsProviderId = "cmux.sidebar.extensions"

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
    static var isEnabled: Bool {
        // Read the single beta-features section, not the whole `SettingCatalog`.
        // Constructing the full catalog allocates ~20 sub-sections (including
        // `AutomationCatalogSection`/`SecretFileKey`) just to reach one flag;
        // doing that on the SwiftUI body's hot path turned the sidebar
        // re-render into a CPU catastrophe (issue #5970).
        let key = BetaFeaturesCatalogSection().extensions
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    static var providers: [any CmuxSidebarProvider] {
        SidebarExamples.providers
    }

    // MARK: - Custom sidebars (beta)

    /// Provider-id prefix for user/agent-authored custom sidebars. The
    /// suffix after the prefix is the sidebar's file base name.
    static let customSidebarProviderPrefix = "cmux.sidebar.custom."

    /// Synchronous read of the Conversations sidebar gate: the local beta
    /// opt-in and the remote release flag must both be on.
    static var conversationSidebarEnabled: Bool {
        let key = BetaFeaturesCatalogSection().conversationSidebar
        let localOptIn = Bool.decodeFromUserDefaults(
            UserDefaults.standard.object(forKey: key.userDefaultsKey)
        ) ?? key.defaultValue
        // The beta toggle is intentionally subordinate to the remote release
        // gate. This keeps the picker and persisted selection recoverable while
        // allowing PostHog to roll the feature out or kill it without shipping.
        let releaseEnabled = CmuxFeatureFlags.offMainEffectiveValue(
            for: CmuxFeatureFlags.conversationSidebarFlag
        )
        return localOptIn && releaseEnabled
    }

    /// Synchronous read of the experimental custom-sidebars flag, mirroring
    /// ``isEnabled`` for the AppKit/static paths (the picker menu).
    static var customSidebarsEnabled: Bool {
        customSidebarsEnabled(defaults: .standard)
    }

    static func customSidebarsEnabled(defaults: UserDefaults) -> Bool {
        // `DisableCustomSidebars` (MDM): interpreted sidebars are user- or
        // agent-authored code that can dispatch `cmux(...)` commands.
        guard !ManagedDevicePolicy().isEnforced(.disableCustomSidebars) else { return false }
        // See ``isEnabled``: read only the beta-features section so a body-path
        // access does not allocate the entire `SettingCatalog` (issue #5970).
        let key = BetaFeaturesCatalogSection().customSidebars
        return Bool.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    static var customSidebarsDirectory: URL {
        #if DEBUG
        if let override = customSidebarsDirectoryOverrideForTesting { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.json` file in the
    /// sidebars directory (`.swift` preferred when both exist), titled by the
    /// file's base name.
    static var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard !ManagedDevicePolicy().isEnforced(.disableCustomSidebars) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        // Priority when several extensions share a base name: js > swift > json.
        func priority(_ ext: String?) -> Int {
            switch ext {
            case "js": return 3
            case "swift": return 2
            case "json": return 1
            default: return 0
            }
        }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard priority(ext) > 0 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if priority(extensionByName[name]) >= priority(ext) { continue }
            extensionByName[name] = ext
        }
        return extensionByName.keys.sorted().map { name in
            CmuxSidebarProviderDescriptor(
                id: customSidebarProviderPrefix + name,
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
    static func customSidebarFileURL(forProviderId providerId: String) -> URL? {
        customSidebarFileURL(forProviderId: providerId, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forProviderId providerId: String, sidebarsDirectory: URL) -> URL? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        guard isValidCustomSidebarFileBaseName(name) else { return nil }
        for ext in ["js", "swift", "json"] {
            let url = sidebarsDirectory.appendingPathComponent("\(name).\(ext)", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func isValidCustomSidebarFileBaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name == (name as NSString).lastPathComponent
    }

    /// Picker descriptor for the built-in Conversations sidebar.
    static var conversationSidebarDescriptor: CmuxSidebarProviderDescriptor {
        CmuxSidebarProviderDescriptor(
            id: conversationSidebarProviderId,
            title: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.conversations.title",
                defaultValue: "Conversations"
            ),
            subtitle: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.conversations.subtitle",
                defaultValue: "Coding-agent sessions"
            ),
            systemImageName: "bubble.left.and.bubble.right",
            isHostProvided: false
        )
    }

    /// The always-available built-in views: the default workspaces sidebar plus
    /// the bundled preset providers (Project Worktrees, Attention Queue, Dev
    /// Servers, Last Prompt, Super Compact, Browser Stack). These ship
    /// independently of the experimental Extensions feature, so they stay in
    /// the switcher menu regardless of the beta flag.
    static var builtInDescriptors: [CmuxSidebarProviderDescriptor] {
        [.defaultWorkspaces] + providers.map { $0.descriptor }
    }

    /// Descriptors offered in the switcher menu and command palette. The hosted
    /// extension entry belongs to the experimental Extensions feature, so it is
    /// only offered while that beta is enabled; the built-in views are always
    /// offered.
    static var descriptors: [CmuxSidebarProviderDescriptor] {
        var result = builtInDescriptors
        if conversationSidebarEnabled {
            result.insert(conversationSidebarDescriptor, at: min(1, result.count))
        }
        if isEnabled { result.append(hostedExtensionsDescriptor) }
        if customSidebarsEnabled { result += customSidebarDescriptors }
        return result
    }

    /// Every descriptor that can ever be selected, ignoring feature gates. Used
    /// to register command-palette handlers so a runtime flag flip always has a
    /// handler to invoke; what is *shown* uses ``descriptors``.
    static var allDescriptors: [CmuxSidebarProviderDescriptor] {
        [.defaultWorkspaces, conversationSidebarDescriptor]
            + providers.map { $0.descriptor }
            + [hostedExtensionsDescriptor]
            + customSidebarDescriptors
    }

    static var hostedExtensionsDescriptor: CmuxSidebarProviderDescriptor {
        let selectedName = UserDefaults.standard.string(forKey: selectedExtensionNameDefaultsKey)?.nilIfEmpty
        return CmuxSidebarProviderDescriptor(
            id: hostedExtensionsProviderId,
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

    static func descriptor(for providerId: String) -> CmuxSidebarProviderDescriptor {
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
    /// The input must be ``effectiveProviderId``'s output: that already routes a
    /// hosted/custom selection back to the default sidebar while its feature gate
    /// is off, so this only needs to confirm the resolved id maps to a renderable
    /// non-default view.
    static func resolvesToDefaultSidebar(effectiveProviderId id: String) -> Bool {
        if id == defaultProviderId { return true }
        if id == conversationSidebarProviderId { return false }
        if id == hostedExtensionsProviderId { return false }
        if id.hasPrefix(customSidebarProviderPrefix) {
            // A custom selection survives only while its backing file exists;
            // otherwise the descriptor lookup falls back to the default sidebar.
            return customSidebarFileURL(forProviderId: id) == nil
        }
        // Bundled preset providers are always registered regardless of any beta
        // flag; an unknown/stale id has no provider and falls back to default.
        return provider(for: id) == nil
    }

    static func provider(for providerId: String) -> (any CmuxSidebarProvider)? {
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
    static func effectiveProviderId(_ persistedProviderId: String, extensionsEnabled: Bool) -> String {
        if persistedProviderId == hostedExtensionsProviderId, !extensionsEnabled {
            return defaultProviderId
        }
        return persistedProviderId
    }

    static func effectiveProviderId(
        _ persistedProviderId: String,
        extensionsEnabled: Bool,
        customSidebarsEnabled: Bool,
        conversationSidebarEnabled: Bool = false
    ) -> String {
        if persistedProviderId == conversationSidebarProviderId, !conversationSidebarEnabled {
            return defaultProviderId
        }
        if persistedProviderId.hasPrefix(customSidebarProviderPrefix), !customSidebarsEnabled {
            return defaultProviderId
        }
        return effectiveProviderId(
            persistedProviderId,
            extensionsEnabled: extensionsEnabled
        )
    }

    static func localizedTitle(for descriptor: CmuxSidebarProviderDescriptor) -> String {
        localizedText(descriptor.title)
    }

    static func localizedText(_ text: CmuxSidebarProviderLocalizedText) -> String {
        NSLocalizedString(
            text.key,
            tableName: "Localizable",
            bundle: .main,
            value: text.defaultValue,
            comment: ""
        )
    }

    @MainActor
    static func setProviderId(_ providerId: String, defaults: UserDefaults = .standard, source: String = "selection") {
        let previous = defaults.string(forKey: defaultsKey) ?? defaultProviderId
        defaults.set(providerId, forKey: defaultsKey)
        TerminalController.shared.sidebarRecoveryDiagnostics.providerChanged(
            previous: previous, current: providerId, source: source
        )
    }

    static func clearStaleTemplatePreviewSelection(defaults: UserDefaults = .standard) {
        guard let providerId = defaults.string(forKey: defaultsKey),
              providerId.hasPrefix(customSidebarProviderPrefix + ".cmux-preview-") else { return }
        defaults.removeObject(forKey: defaultsKey)
    }

    @MainActor
    static func setInMemoryTemplatePreview(providerId: String, source: String) {
        inMemoryTemplatePreview = (providerId, source)
    }

    @MainActor
    static func clearInMemoryTemplatePreview() {
        inMemoryTemplatePreview = nil
    }

    @MainActor
    static func inMemoryTemplatePreviewSource(for providerId: String) -> String? {
        guard inMemoryTemplatePreview?.providerId == providerId else { return nil }
        return inMemoryTemplatePreview?.source
    }

    /// Moves a selection saved under `legacyDefaultsKey` before #13930.
    /// A selection already stored under `defaultsKey` wins; the legacy key is removed.
    static func migrateLegacyDefaultsKeyIfNeeded(defaults: UserDefaults = .standard) {
        guard let legacyProviderId = defaults.object(forKey: legacyDefaultsKey) else { return }
        defaults.removeObject(forKey: legacyDefaultsKey)
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        defaults.set(legacyProviderId, forKey: defaultsKey)
    }

    @MainActor
    static func browseTemplates() {
        guard customSidebarsEnabled else { return }
        AppDelegate.shared?.openPreferencesWindow(
            debugSource: "sidebar.browseTemplates",
            navigationTarget: .customSidebars
        )
        SettingsNavigationRequest.post(.customSidebars, anchorID: "setting:customSidebars:templates", highlight: true)
        CustomSidebarTemplateGalleryRequest.shared.request()
    }

    static func isCortexBundle(_ bundleID: String, hostBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if bundleID == "fr.yoyaku.cortex.sessions" || bundleID == "fr.yoyaku.cortex.sessions.debug" { return true }
        // Tagged native hosts embed the extension under their own bundle identity.
        if let hostBundleID, hostBundleID.hasPrefix("com.cmuxterm.app.debug."), bundleID == hostBundleID + ".sessions" { return true }
        let prefix = "fr.yoyaku.cortex.dogfood."
        let suffix = ".sessions"
        guard bundleID.hasPrefix(prefix), bundleID.hasSuffix(suffix), let hostBundleID else { return false }
        let tag = String(bundleID.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        }) else { return false }
        return hostBundleID == "com.cmuxterm.app.debug.\(parts.joined(separator: "."))"
    }

    static func isCortexActive(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: defaultsKey) == hostedExtensionsProviderId
            && isCortexBundle(defaults.string(forKey: selectedExtensionBundleIDDefaultsKey) ?? "")
    }

    /// Changes only the sidebar provider; workspace, surface and terminal state
    /// remain owned by their existing native models.
    @MainActor
    @discardableResult
    static func toggleCortexSidebar(
        enabledBundleIDs: Set<String>,
        extensionsEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if isCortexActive(defaults: defaults) {
            setProviderId(defaultProviderId, defaults: defaults)
            return true
        }
        guard extensionsEnabled,
              let bundleID = enabledBundleIDs.filter({ isCortexBundle($0) }).sorted().first else { return false }
        defaults.set(bundleID, forKey: selectedExtensionBundleIDDefaultsKey)
        defaults.set("Cortex Sessions", forKey: selectedExtensionNameDefaultsKey)
        setProviderId(hostedExtensionsProviderId, defaults: defaults)
        return true
    }

    /// Explicit, idempotent selection for the permanent sidebar mode header.
    /// Discovery only supplies candidates and never writes this preference.
    @MainActor
    @discardableResult
    static func selectCortexSidebar(
        enabledBundleIDs: Set<String>,
        extensionsEnabled: Bool,
        defaults: UserDefaults = .standard,
        hostBundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard extensionsEnabled else { return false }
        let candidates = enabledBundleIDs.filter { isCortexBundle($0, hostBundleID: hostBundleID) }.sorted()
        let retained = defaults.string(forKey: selectedExtensionBundleIDDefaultsKey)
        guard let bundleID = retained.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.first else { return false }
        defaults.set(bundleID, forKey: selectedExtensionBundleIDDefaultsKey)
        defaults.set("Cortex Sessions", forKey: selectedExtensionNameDefaultsKey)
        setProviderId(hostedExtensionsProviderId, defaults: defaults)
        return true
    }

    @MainActor
    static func showMenu(anchorView: NSView, event: NSEvent?) {
        // The right-click menu switches between the always-available built-in
        // views (and the hosted extension sidebar when the experimental
        // Extensions beta is enabled, plus any beta custom sidebars), so it is
        // shown regardless of the flag.
        let menu = NSMenu()
        let persistedProviderId = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultProviderId
        let selectedProviderId = descriptor(
            for: effectiveProviderId(
                persistedProviderId,
                extensionsEnabled: isEnabled,
                customSidebarsEnabled: customSidebarsEnabled,
                conversationSidebarEnabled: conversationSidebarEnabled
            )
        ).id
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: localizedTitle(for: descriptor),
                action: #selector(CmuxExtensionSidebarMenuTarget.selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = descriptor.id
            item.target = CmuxExtensionSidebarMenuTarget.shared
            item.state = selectedProviderId == descriptor.id ? .on : .off
            item.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if customSidebarsEnabled {
            menu.addItem(.separator())
            let templatesItem = NSMenuItem(
                title: String(localized: "sidebar.menu.browseTemplates", defaultValue: "Browse Sidebar Templates…"),
                action: #selector(CmuxExtensionSidebarMenuTarget.browseTemplates),
                keyEquivalent: ""
            )
            templatesItem.target = CmuxExtensionSidebarMenuTarget.shared
            menu.addItem(templatesItem)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }
}

@MainActor
private final class CmuxExtensionSidebarMenuTarget: NSObject {
    static let shared = CmuxExtensionSidebarMenuTarget()

    @objc func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? String else { return }
        CmuxExtensionSidebarSelection.setProviderId(providerId, source: "sidebar_menu")
    }

    @objc func browseTemplates() {
        CmuxExtensionSidebarSelection.browseTemplates()
    }
}
