import Foundation
import Testing
@testable import CmuxSettings

/// Behavior tests for the Wave-2 domain settings repositories that replaced
/// the cmuxApp static settings-namespace enums. Each suite pins the legacy
/// read/write semantics (defaults, legacy-key fallback chains, trim rules)
/// against a scratch `UserDefaults` suite.
private func makeScratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
}

@Suite("DefaultsKey direct access")
struct DefaultsKeyDirectAccessTests {
    @Test func readsDefaultWhenUnsetAndRoundTrips() {
        let defaults = makeScratchDefaults()
        let key = AppCatalogSection().warnBeforeClosingTab
        #expect(key.value(in: defaults) == true)
        #expect(!key.hasStoredValue(in: defaults))

        key.set(false, in: defaults)
        #expect(key.value(in: defaults) == false)
        #expect(key.hasStoredValue(in: defaults))

        key.removeValue(in: defaults)
        #expect(key.value(in: defaults) == true)
    }

    @Test func undecodableStoredValueReadsAsDefault() {
        let defaults = makeScratchDefaults()
        let key = AppCatalogSection().confirmQuitMode
        defaults.set("not-a-mode", forKey: key.userDefaultsKey)
        #expect(key.value(in: defaults) == .always)
        #expect(key.hasStoredValue(in: defaults))
    }

    @Test func matchesStoreDecodePath() async {
        // Two handles onto the same suite: the actor store writes through
        // one, the synchronous key accessor reads through the other.
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let key = AppCatalogSection().appearance
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        await store.set(.dark, for: key)
        let storeValue = await store.value(for: key)
        #expect(storeValue == .dark)
        #expect(key.value(in: UserDefaults(suiteName: suiteName)!) == .dark)
    }
}

@Suite("CloseTabWarningStore")
struct CloseTabWarningStoreTests {
    @Test func defaultsMatchLegacyNamespace() {
        let store = CloseTabWarningStore(defaults: makeScratchDefaults())
        #expect(store.warnsBeforeClosingTab == true)
        #expect(store.warnsBeforeClosingTabXButton == false)
        #expect(store.hidesTabCloseButton == false)
    }

    @Test func readsStoredOverridesUnderLegacyKeys() {
        let defaults = makeScratchDefaults()
        defaults.set(false, forKey: "warnBeforeClosingTabShortcut")
        defaults.set(true, forKey: "warnBeforeClosingTabXButton")
        defaults.set(true, forKey: "hideTabCloseButton")
        let store = CloseTabWarningStore(defaults: defaults)
        #expect(store.warnsBeforeClosingTab == false)
        #expect(store.warnsBeforeClosingTabXButton == true)
        #expect(store.hidesTabCloseButton == true)
    }

    @Test func setWarnsBeforeClosingTabWritesLegacyKey() {
        let defaults = makeScratchDefaults()
        let store = CloseTabWarningStore(defaults: defaults)
        store.setWarnsBeforeClosingTab(false)
        #expect(defaults.object(forKey: "warnBeforeClosingTabShortcut") as? Bool == false)
    }
}

@Suite("CommandPaletteSettingsStore")
struct CommandPaletteSettingsStoreTests {
    @Test func defaultsMatchLegacyNamespace() {
        let store = CommandPaletteSettingsStore(defaults: makeScratchDefaults())
        #expect(store.renameSelectsAllOnFocus == true)
        #expect(store.switcherSearchesAllSurfaces == false)
    }

    @Test func readsStoredOverridesUnderLegacyKeys() {
        let defaults = makeScratchDefaults()
        defaults.set(false, forKey: "commandPalette.renameSelectAllOnFocus")
        defaults.set(true, forKey: "commandPalette.switcherSearchAllSurfaces")
        let store = CommandPaletteSettingsStore(defaults: defaults)
        #expect(store.renameSelectsAllOnFocus == false)
        #expect(store.switcherSearchesAllSurfaces == true)
    }
}

@Suite("AgentIntegrationSettingsStore")
struct AgentIntegrationSettingsStoreTests {
    @Test func defaultsMatchLegacyRuntimeBehavior() {
        let store = AgentIntegrationSettingsStore(defaults: makeScratchDefaults())
        #expect(store.claudeCodeHooksEnabled == true)
        #expect(store.cursorHooksEnabled == true)
        #expect(store.geminiHooksEnabled == true)
        #expect(store.kiroHooksEnabled == true)
        #expect(store.ampHooksEnabled == true)
        #expect(store.suppressesSubagentNotifications == true)
        #expect(store.customClaudePath == nil)
        #expect(store.kiroNotificationLevel == .standard)
    }

    @Test func readsStoredOverridesUnderLegacyKeys() {
        let defaults = makeScratchDefaults()
        defaults.set(false, forKey: "claudeCodeHooksEnabled")
        defaults.set(false, forKey: "cursorHooksEnabled")
        defaults.set(false, forKey: "geminiHooksEnabled")
        defaults.set(false, forKey: "kiroHooksEnabled")
        defaults.set(false, forKey: "ampHooksEnabled")
        defaults.set(false, forKey: "suppressSubagentNotifications")
        let store = AgentIntegrationSettingsStore(defaults: defaults)
        #expect(store.claudeCodeHooksEnabled == false)
        #expect(store.cursorHooksEnabled == false)
        #expect(store.geminiHooksEnabled == false)
        #expect(store.kiroHooksEnabled == false)
        #expect(store.ampHooksEnabled == false)
        #expect(store.suppressesSubagentNotifications == false)
    }

    @Test func customClaudePathTrimsAndNilsEmpty() {
        let defaults = makeScratchDefaults()
        let store = AgentIntegrationSettingsStore(defaults: defaults)

        defaults.set("   ", forKey: "claudeCodeCustomClaudePath")
        #expect(store.customClaudePath == nil)

        defaults.set("  /usr/local/bin/claude \n", forKey: "claudeCodeCustomClaudePath")
        #expect(store.customClaudePath == "/usr/local/bin/claude")
    }

    @Test func kiroNotificationLevelParsesAndFallsBackToStandard() {
        let defaults = makeScratchDefaults()
        let store = AgentIntegrationSettingsStore(defaults: defaults)

        defaults.set("verbose", forKey: "kiroNotificationLevel")
        #expect(store.kiroNotificationLevel == .verbose)

        defaults.set("minimal", forKey: "kiroNotificationLevel")
        #expect(store.kiroNotificationLevel == .minimal)

        defaults.set("unsupported", forKey: "kiroNotificationLevel")
        #expect(store.kiroNotificationLevel == .standard)
    }
}

@Suite("QuitConfirmationStore")
struct QuitConfirmationStoreTests {
    @Test func neverSetDefaultsToAlways() {
        let store = QuitConfirmationStore(defaults: makeScratchDefaults())
        #expect(store.confirmQuitMode == .always)
        #expect(store.isEnabled)
    }

    @Test func storedModeStringWins() {
        let defaults = makeScratchDefaults()
        defaults.set("dirty-only", forKey: "confirmQuit")
        // Even with a contradicting legacy boolean present.
        defaults.set(false, forKey: "warnBeforeQuitShortcut")
        let store = QuitConfirmationStore(defaults: defaults)
        #expect(store.confirmQuitMode == .dirtyOnly)
    }

    @Test func unrecognizedModeStringFallsThroughToLegacyBoolean() {
        let defaults = makeScratchDefaults()
        defaults.set("sometimes", forKey: "confirmQuit")
        defaults.set(false, forKey: "warnBeforeQuitShortcut")
        let store = QuitConfirmationStore(defaults: defaults)
        #expect(store.confirmQuitMode == .never)
    }

    @Test func legacyBooleanMapsToAlwaysOrNever() {
        let defaults = makeScratchDefaults()
        let store = QuitConfirmationStore(defaults: defaults)

        defaults.set(true, forKey: "warnBeforeQuitShortcut")
        #expect(store.confirmQuitMode == .always)

        defaults.set(false, forKey: "warnBeforeQuitShortcut")
        #expect(store.confirmQuitMode == .never)
        #expect(!store.isEnabled)
    }

    @Test func setModeMirrorsLegacyBoolean() {
        let defaults = makeScratchDefaults()
        let store = QuitConfirmationStore(defaults: defaults)

        store.setMode(.never)
        #expect(defaults.string(forKey: "confirmQuit") == "never")
        #expect(defaults.object(forKey: "warnBeforeQuitShortcut") as? Bool == false)

        store.setMode(.dirtyOnly)
        #expect(defaults.string(forKey: "confirmQuit") == "dirty-only")
        #expect(defaults.object(forKey: "warnBeforeQuitShortcut") as? Bool == true)
    }

    @Test func setEnabledMapsToAlwaysAndNever() {
        let defaults = makeScratchDefaults()
        let store = QuitConfirmationStore(defaults: defaults)

        store.setEnabled(false)
        #expect(store.confirmQuitMode == .never)

        store.setEnabled(true)
        #expect(store.confirmQuitMode == .always)
    }
}

@Suite("FileRouteSettingsStore")
struct FileRouteSettingsStoreTests {
    private func makeStore() -> (FileRouteSettingsStore, UserDefaults, NotificationCenter) {
        let defaults = makeScratchDefaults()
        let center = NotificationCenter()
        let store = FileRouteSettingsStore(
            defaults: defaults,
            notificationCenter: center
        )
        return (store, defaults, center)
    }

    private func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-route-\(UUID().uuidString).md")
        try Data("# hi\n".utf8).write(to: url)
        return url
    }

    @Test func defaultsMatchLegacyRuntimeBehavior() {
        let (store, _, _) = makeStore()
        #expect(store.markdownRouteEnabled == true)
        #expect(store.supportedFileRouteEnabled == true)
    }

    @Test func markdownExtensionMatrix() {
        #expect(FileRouteSettingsStore.isMarkdownPath("/a/readme.md"))
        #expect(FileRouteSettingsStore.isMarkdownPath("/a/README.MARKDOWN"))
        #expect(FileRouteSettingsStore.isMarkdownPath("/a/notes.mkd"))
        #expect(FileRouteSettingsStore.isMarkdownPath("/a/page.mdx"))
        #expect(!FileRouteSettingsStore.isMarkdownPath("/a/main.swift"))
        #expect(!FileRouteSettingsStore.isMarkdownPath("/a/md"))
    }

    @Test func routesOnlyReadableRegularFiles() throws {
        let (store, _, _) = makeStore()
        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(store.shouldRouteMarkdown(path: file.path))
        #expect(store.shouldRouteSupportedFile(path: file.path))
        // A directory is not a regular file.
        #expect(!store.shouldRouteSupportedFile(path: FileManager.default.temporaryDirectory.path))
        // A missing path is not readable.
        #expect(!store.shouldRouteMarkdown(path: "/nonexistent/cmux-test.md"))
    }

    @Test func disabledTogglesShortCircuitRouting() throws {
        let (store, defaults, _) = makeStore()
        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        defaults.set(false, forKey: "openMarkdownInCmuxViewer")
        #expect(!store.shouldRouteMarkdown(path: file.path))

        defaults.set(false, forKey: "openSupportedFilesInCmux")
        #expect(!store.shouldRouteSupportedFile(path: file.path))
    }

    @Test func setsPostDidChangeNotifications() {
        let (store, defaults, center) = makeStore()

        nonisolated(unsafe) var markdownPosts = 0
        nonisolated(unsafe) var supportedPosts = 0
        let markdownToken = center.addObserver(
            forName: FileRouteSettingsStore.markdownRouteDidChange,
            object: nil,
            queue: nil
        ) { _ in markdownPosts += 1 }
        let supportedToken = center.addObserver(
            forName: FileRouteSettingsStore.supportedFileRouteDidChange,
            object: nil,
            queue: nil
        ) { _ in supportedPosts += 1 }
        defer {
            center.removeObserver(markdownToken)
            center.removeObserver(supportedToken)
        }

        store.setMarkdownRouteEnabled(false)
        store.setSupportedFileRouteEnabled(false)
        #expect(defaults.object(forKey: "openMarkdownInCmuxViewer") as? Bool == false)
        #expect(defaults.object(forKey: "openSupportedFilesInCmux") as? Bool == false)
        #expect(markdownPosts == 1)
        #expect(supportedPosts == 1)
    }
}

@Suite("PreferredEditorSettingsStore")
struct PreferredEditorSettingsStoreTests {
    @Test func unsetReadsNil() {
        let store = PreferredEditorSettingsStore(defaults: makeScratchDefaults())
        #expect(store.resolvedCommand == nil)
    }

    @Test func whitespaceOnlyReadsNil() {
        let defaults = makeScratchDefaults()
        defaults.set("   \n\t", forKey: "preferredEditorCommand")
        let store = PreferredEditorSettingsStore(defaults: defaults)
        #expect(store.resolvedCommand == nil)
    }

    @Test func trimsStoredCommand() {
        let defaults = makeScratchDefaults()
        defaults.set("  code -w  \n", forKey: "preferredEditorCommand")
        let store = PreferredEditorSettingsStore(defaults: defaults)
        #expect(store.resolvedCommand == "code -w")
    }

    @Test func returnsConfiguredCommandWhenSet() {
        let defaults = makeScratchDefaults()
        defaults.set("code", forKey: "preferredEditorCommand")
        let store = PreferredEditorSettingsStore(defaults: defaults)
        #expect(store.resolvedCommand == "code")
    }
}

@Suite("AppIconSettingsStore")
struct AppIconSettingsStoreTests {
    @Test func unsetAndInvalidReadAutomatic() {
        let defaults = makeScratchDefaults()
        let store = AppIconSettingsStore(defaults: defaults)
        #expect(store.resolvedMode == .automatic)

        defaults.set("neon", forKey: "appIconMode")
        #expect(store.resolvedMode == .automatic)
    }

    @Test func readsStoredMode() {
        let defaults = makeScratchDefaults()
        defaults.set("dark", forKey: "appIconMode")
        let store = AppIconSettingsStore(defaults: defaults)
        #expect(store.resolvedMode == .dark)
    }
}

@Suite("LanguageSettingsStore")
struct LanguageSettingsStoreTests {
    @Test func unsetAndInvalidReadSystem() {
        let defaults = makeScratchDefaults()
        let store = LanguageSettingsStore(defaults: defaults)
        #expect(store.storedLanguage == .system)

        defaults.set("klingon", forKey: "appLanguage")
        #expect(store.storedLanguage == .system)
    }

    @Test func readsStoredLanguage() {
        let defaults = makeScratchDefaults()
        defaults.set("ja", forKey: "appLanguage")
        let store = LanguageSettingsStore(defaults: defaults)
        #expect(store.storedLanguage == .ja)
    }

    @Test func applyLanguageOverrideWritesAppleLanguagesList() {
        // `AppleLanguages` also exists in the global defaults domain, so a
        // plain read never returns nil; assert on the suite's persistent
        // domain to observe only the override this store writes/removes.
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = LanguageSettingsStore(defaults: defaults)

        store.applyLanguageOverride(.ja)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == ["ja"])

        store.applyLanguageOverride(.system)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
    }
}

@Suite("Close-tab confirmation policy")
struct CloseTabConfirmationPolicyTests {
    private struct FixedWarnings: CloseTabWarningReading {
        var warnsBeforeClosingTab: Bool
        var warnsBeforeClosingTabXButton: Bool
        var hidesTabCloseButton: Bool = false
    }

    @Test func shortcutWarnsOnlyForConfirmationRequiringTabsWithWarningOn() {
        let warningOn = FixedWarnings(warnsBeforeClosingTab: true, warnsBeforeClosingTabXButton: false)
        let warningOff = FixedWarnings(warnsBeforeClosingTab: false, warnsBeforeClosingTabXButton: false)

        #expect(warningOn.shouldConfirmClose(requiresConfirmation: true, source: .shortcut))
        #expect(!warningOn.shouldConfirmClose(requiresConfirmation: false, source: .shortcut))
        #expect(!warningOff.shouldConfirmClose(requiresConfirmation: true, source: .shortcut))
        #expect(!warningOff.shouldConfirmClose(requiresConfirmation: false, source: .shortcut))
    }

    @Test func xButtonWarnsUnconditionallyWhenItsToggleIsOn() {
        let xButtonOnly = FixedWarnings(warnsBeforeClosingTab: false, warnsBeforeClosingTabXButton: true)
        #expect(xButtonOnly.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton))
        #expect(xButtonOnly.shouldConfirmClose(requiresConfirmation: true, source: .tabCloseButton))
    }

    @Test func xButtonAlsoWarnsThroughTheShortcutToggleForConfirmationRequiringTabs() {
        let shortcutOnly = FixedWarnings(warnsBeforeClosingTab: true, warnsBeforeClosingTabXButton: false)
        #expect(shortcutOnly.shouldConfirmClose(requiresConfirmation: true, source: .tabCloseButton))
        #expect(!shortcutOnly.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton))

        let bothOff = FixedWarnings(warnsBeforeClosingTab: false, warnsBeforeClosingTabXButton: false)
        #expect(!bothOff.shouldConfirmClose(requiresConfirmation: true, source: .tabCloseButton))
        #expect(!bothOff.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton))
    }

    @Test func liveStoreReadsTogglesFromDefaults() {
        let defaults = makeScratchDefaults()
        defaults.set(false, forKey: "warnBeforeClosingTabShortcut")
        defaults.set(true, forKey: "warnBeforeClosingTabXButton")
        let store = CloseTabWarningStore(defaults: defaults)

        #expect(!store.shouldConfirmClose(requiresConfirmation: true, source: .shortcut))
        #expect(store.shouldConfirmClose(requiresConfirmation: false, source: .tabCloseButton))
    }
}

@Suite("Quit confirmation policy")
struct QuitConfirmationPolicyTests {
    @Test func priorConfirmationSkipsTheDialog() {
        let store = QuitConfirmationStore(defaults: makeScratchDefaults())
        #expect(!store.shouldShowConfirmation(
            isQuitWarningConfirmed: true, hasDirtyWorkspaces: true, isDevBuild: false
        ))
    }

    @Test func devBuildsNeverWarn() {
        let store = QuitConfirmationStore(defaults: makeScratchDefaults())
        #expect(!store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: true, isDevBuild: true
        ))
    }

    @Test func alwaysModeWarnsRegardlessOfDirtyState() {
        let store = QuitConfirmationStore(defaults: makeScratchDefaults())
        #expect(store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: false, isDevBuild: false
        ))
        #expect(store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: true, isDevBuild: false
        ))
    }

    @Test func dirtyOnlyModeWarnsOnlyWithDirtyWorkspaces() {
        let defaults = makeScratchDefaults()
        defaults.set("dirty-only", forKey: "confirmQuit")
        let store = QuitConfirmationStore(defaults: defaults)

        #expect(store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: true, isDevBuild: false
        ))
        #expect(!store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: false, isDevBuild: false
        ))
    }

    @Test func neverModeNeverWarns() {
        let defaults = makeScratchDefaults()
        defaults.set("never", forKey: "confirmQuit")
        let store = QuitConfirmationStore(defaults: defaults)

        #expect(!store.shouldShowConfirmation(
            isQuitWarningConfirmed: false, hasDirtyWorkspaces: true, isDevBuild: false
        ))
    }
}
