@testable import CmuxNextSettings
import Testing

/// `browser.allowIPhoneAccess` exposes every Chromium tab to local processes,
/// so only an explicit `true` turns it on.
@Suite struct IPhoneAccessSettingTests {
    func snapshot(_ browser: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = browser.map { .object(["browser": .object($0)]) } ?? .object([:])
        return CmuxConfigSnapshot(root: root, density: nil, metrics: [:], shortcuts: [:], diagnostics: [])
    }

    @Test func offWhenUnset() {
        #expect(!snapshot(nil).browserAllowsIPhoneAccess)
        #expect(!snapshot([:]).browserAllowsIPhoneAccess)
    }

    @Test func onOnlyForTrue() {
        #expect(snapshot(["allowIPhoneAccess": .bool(true)]).browserAllowsIPhoneAccess)
        #expect(!snapshot(["allowIPhoneAccess": .bool(false)]).browserAllowsIPhoneAccess)
        #expect(!snapshot(["allowIPhoneAccess": .string("true")]).browserAllowsIPhoneAccess)
    }

    @Test func schemaRowIsAnOffToggle() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == CmuxConfigSnapshot.browserAllowIPhoneAccessPath })
        #expect(row.defaultValue == .bool(false))
        #expect(row.help?.contains("restarting cmux") == true)
    }
}
