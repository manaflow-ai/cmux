import Foundation
import Testing
@testable import CmuxSettings

@Suite("SidebarAppearanceDefaultsMigration")
struct SidebarAppearanceDefaultsMigrationTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SidebarAppearanceDefaultsMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test func freshDefaultsAreRewrittenToNativeSidebarPreset() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An empty suite reads the legacy sentinel defaults, so the migration
        // should treat it as untouched and re-seed the native-sidebar preset.
        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()

        #expect(defaults.string(forKey: "sidebarPreset") == "nativeSidebar")
        #expect(defaults.string(forKey: "sidebarMaterial") == "sidebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "withinWindow")
        #expect(defaults.string(forKey: "sidebarState") == "followWindow")
        #expect(defaults.string(forKey: "sidebarTintHex") == "#000000")
        #expect(defaults.object(forKey: "sidebarTintOpacity") as? Double == 0.18)
        #expect(defaults.object(forKey: "sidebarBlurOpacity") as? Double == 1.0)
        #expect(defaults.object(forKey: "sidebarCornerRadius") as? Double == 0.0)
        #expect(defaults.integer(forKey: SidebarAppearanceDefaultsMigration.versionKey) == 1)
    }

    @Test func explicitLegacyValuesAreRewritten() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("sidebar", forKey: "sidebarMaterial")
        defaults.set("behindWindow", forKey: "sidebarBlendMode")
        defaults.set("followWindow", forKey: "sidebarState")
        defaults.set("#101010", forKey: "sidebarTintHex")
        defaults.set(0.54, forKey: "sidebarTintOpacity")
        defaults.set(0.79, forKey: "sidebarBlurOpacity")
        defaults.set(0.0, forKey: "sidebarCornerRadius")

        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()

        #expect(defaults.string(forKey: "sidebarPreset") == "nativeSidebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "withinWindow")
        #expect(defaults.string(forKey: "sidebarTintHex") == "#000000")
        #expect(defaults.integer(forKey: SidebarAppearanceDefaultsMigration.versionKey) == 1)
    }

    @Test func hexComparisonIsCaseAndHashInsensitive() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // " 101010 " with no hash and surrounding whitespace still normalizes
        // to the legacy hex, so the migration treats the suite as untouched.
        defaults.set("  101010  ", forKey: "sidebarTintHex")

        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()

        #expect(defaults.string(forKey: "sidebarTintHex") == "#000000")
        #expect(defaults.string(forKey: "sidebarPreset") == "nativeSidebar")
    }

    @Test func customizedSidebarIsLeftUntouchedButVersionStamped() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A single differing key marks the sidebar as customized.
        defaults.set("hudWindow", forKey: "sidebarMaterial")

        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()

        // Keys are left as the user had them.
        #expect(defaults.string(forKey: "sidebarMaterial") == "hudWindow")
        #expect(defaults.string(forKey: "sidebarPreset") == nil)
        #expect(defaults.string(forKey: "sidebarBlendMode") == nil)
        // But the version is still stamped so the migration runs at most once.
        #expect(defaults.integer(forKey: SidebarAppearanceDefaultsMigration.versionKey) == 1)
    }

    @Test func alreadyMigratedSuiteIsNotRewritten() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Version already at target with legacy-looking values present: the
        // migration must no-op rather than re-seed the preset.
        defaults.set(1, forKey: SidebarAppearanceDefaultsMigration.versionKey)
        defaults.set("sidebar", forKey: "sidebarMaterial")
        defaults.set("behindWindow", forKey: "sidebarBlendMode")
        defaults.set("followWindow", forKey: "sidebarState")
        defaults.set("#101010", forKey: "sidebarTintHex")
        defaults.set(0.54, forKey: "sidebarTintOpacity")

        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()

        #expect(defaults.string(forKey: "sidebarPreset") == nil)
        #expect(defaults.string(forKey: "sidebarMaterial") == "sidebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "behindWindow")
    }

    @Test func migrationIsIdempotent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let migration = SidebarAppearanceDefaultsMigration(defaults: defaults)
        migration.migrate()
        // After the first run the values are the native preset, not the legacy
        // set, so a second run must not touch them again.
        migration.migrate()

        #expect(defaults.string(forKey: "sidebarPreset") == "nativeSidebar")
        #expect(defaults.string(forKey: "sidebarBlendMode") == "withinWindow")
        #expect(defaults.integer(forKey: SidebarAppearanceDefaultsMigration.versionKey) == 1)
    }
}
