import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite struct TerminalSystemAppearanceTests {
    @Test func prefersDarkIsTrueOnlyForDarkInterfaceStyle() {
        #expect(TerminalSystemAppearance(interfaceStyle: "Dark").prefersDark)
        #expect(TerminalSystemAppearance(interfaceStyle: "dark").prefersDark)
        #expect(!TerminalSystemAppearance(interfaceStyle: nil).prefersDark)
        #expect(!TerminalSystemAppearance(interfaceStyle: "Light").prefersDark)
        #expect(!TerminalSystemAppearance(interfaceStyle: "").prefersDark)
    }

    @Test func currentReadsDirectInterfaceStyleValue() {
        let suiteName = "TerminalSystemAppearanceTests.direct.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("Dark", forKey: TerminalSystemAppearance.appleInterfaceStyleKey)
        #expect(TerminalSystemAppearance.current(defaults: defaults).prefersDark)
    }

    @Test func currentReadsLightInterfaceStyleAsNotDark() {
        let suiteName = "TerminalSystemAppearanceTests.light.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A direct non-"Dark" value takes precedence over the global-domain
        // fallback, so the snapshot is deterministically not-dark.
        defaults.set("Light", forKey: TerminalSystemAppearance.appleInterfaceStyleKey)
        let snapshot = TerminalSystemAppearance.current(defaults: defaults)
        #expect(snapshot.interfaceStyle == "Light")
        #expect(!snapshot.prefersDark)
    }
}

@Suite struct TerminalColorSchemePreferenceResolutionTests {
    private let darkSystem = TerminalSystemAppearance(interfaceStyle: "Dark")
    private let lightSystem = TerminalSystemAppearance(interfaceStyle: nil)

    @Test func explicitLightModeWins() {
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: "light",
                systemAppearance: darkSystem
            ) == .light
        )
    }

    @Test func explicitDarkModeWins() {
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: "dark",
                systemAppearance: lightSystem
            ) == .dark
        )
    }

    @Test func systemModeFollowsSystemAppearance() {
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: "system",
                systemAppearance: darkSystem
            ) == .dark
        )
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: "system",
                systemAppearance: lightSystem
            ) == .light
        )
    }

    @Test func unsetAndUnknownModesFollowSystemAppearance() {
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: nil,
                systemAppearance: darkSystem
            ) == .dark
        )
        #expect(
            TerminalColorSchemePreference.resolve(
                appearanceModeRawValue: "totally-unknown",
                systemAppearance: lightSystem
            ) == .light
        )
    }

    @Test func currentReadsPersistedModeFromDefaults() {
        let suiteName = "TerminalColorSchemePreference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("light", forKey: TerminalColorSchemePreference.appearanceModeDefaultsKey)
        #expect(
            TerminalColorSchemePreference.current(
                defaults: defaults,
                systemAppearance: darkSystem
            ) == .light
        )
    }
}

@Suite struct GhosttySplitThemePreferenceTests {
    @Test func storedDarkModeSelectsDarkSplitTheme() {
        let suiteName = "GhosttySplitThemePreferenceTests.storedDark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("dark", forKey: TerminalColorSchemePreference.appearanceModeDefaultsKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            defaults: defaults,
            systemAppearance: TerminalSystemAppearance(interfaceStyle: nil)
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        #expect(preferredColorScheme == .dark)
        #expect(resolvedTheme == "Apple System Colors")
    }

    @Test func storedLightModeSelectsLightSplitTheme() {
        let suiteName = "GhosttySplitThemePreferenceTests.storedLight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("light", forKey: TerminalColorSchemePreference.appearanceModeDefaultsKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            defaults: defaults,
            systemAppearance: TerminalSystemAppearance(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        #expect(preferredColorScheme == .light)
        #expect(resolvedTheme == "Catppuccin Latte")
    }

    @Test func systemLightModeSelectsLightSplitTheme() {
        let suiteName = "GhosttySplitThemePreferenceTests.systemLight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("system", forKey: TerminalColorSchemePreference.appearanceModeDefaultsKey)
        defaults.removeObject(forKey: TerminalSystemAppearance.appleInterfaceStyleKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            defaults: defaults,
            systemAppearance: TerminalSystemAppearance(interfaceStyle: nil)
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        #expect(preferredColorScheme == .light)
        #expect(resolvedTheme == "Monokai Pro Light")
    }

    @Test func systemDarkModeSelectsDarkSplitTheme() {
        let suiteName = "GhosttySplitThemePreferenceTests.systemDark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("system", forKey: TerminalColorSchemePreference.appearanceModeDefaultsKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            defaults: defaults,
            systemAppearance: TerminalSystemAppearance(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        #expect(preferredColorScheme == .dark)
        #expect(resolvedTheme == "Monokai Pro Machine")
    }
}
