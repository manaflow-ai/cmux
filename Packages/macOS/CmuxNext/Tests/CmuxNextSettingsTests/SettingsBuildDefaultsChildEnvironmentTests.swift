@testable import CmuxNextSettings
import Foundation
import Testing

/// The Rust settings owner (the daemon behind `cmux settings get` and MCP `settings_get`) reports the defaults the
/// app uses: the app passes its build defaults as `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS`, a JSON object of dotted keys
/// (cmux-config `build_defaults_from`). One source: ``SettingsBuildDefaults``.
@Suite struct SettingsBuildDefaultsChildEnvironmentTests {
    @Test func aDevBuildPassesItsDefaults() {
        #expect(SettingsBuildDefaults.channel(downloadsAutomatically: false, devBuild: true).childEnvironmentValue
                == #"{"mobile.allowIPhoneConnections":true}"#)
        #expect(SettingsBuildDefaults.channel(downloadsAutomatically: true, devBuild: true).childEnvironmentValue
                == #"{"mobile.allowIPhoneConnections":true,"updates.automatic":"download"}"#)
        #expect(SettingsBuildDefaults.channel(downloadsAutomatically: true).childEnvironmentValue
                == #"{"updates.automatic":"download"}"#)
    }

    @Test func aBuildWithoutDefaultsPassesNothing() {
        #expect(SettingsBuildDefaults.none.childEnvironmentValue == nil)
        #expect(SettingsBuildDefaults.channel(downloadsAutomatically: false).childEnvironmentValue == nil)
    }

    /// Every key it passes is a schema key, so the Rust owner (which ignores unknown keys) applies each.
    @Test func everyKeyIsASetting() throws {
        let defaults = SettingsBuildDefaults.channel(downloadsAutomatically: true, devBuild: true)
        for path in defaults.values.keys {
            #expect(SettingsSchema.all.contains { $0.path == path }, "\(path)")
        }
    }
}
