import CmuxNextSettings
import Foundation
import Testing

/// R114: `updates.*` has great defaults (check, download and install on
/// quit all on, hourly checks, the Settings control) and every step is customizable.
@Suite struct UpdatesSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.updates == UpdatesSettings())
        #expect(snapshot.updates.checkAutomatically)
        #expect(snapshot.updates.checkIntervalSeconds == 3600)
        #expect(snapshot.updates.downloadAutomatically)
        #expect(snapshot.updates.installOnQuit)
        #expect(snapshot.updates.notify == .badge)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryKey() throws {
        let snapshot = try parse(#"""
        {"updates": {"checkAutomatically": false, "checkIntervalSeconds": 86400, "downloadAutomatically": false,
                     "installOnQuit": false, "notify": "silent"}}
        """#)
        #expect(!snapshot.updates.checkAutomatically)
        #expect(snapshot.updates.checkIntervalSeconds == 86400)
        #expect(!snapshot.updates.downloadAutomatically)
        #expect(!snapshot.updates.installOnQuit)
        #expect(snapshot.updates.notify == .silent)
        #expect(snapshot.diagnostics.isEmpty)
    }

    /// WHATS-NEW-AFTER-UPDATE W1: the What's New item is on by default and
    /// can be turned off (managed config can force it off the same way).
    @Test func showWhatsNewDefaultsOnAndTurnsOff() throws {
        #expect(try parse("{}").updates.showWhatsNew)
        let off = try parse(#"{"updates": {"showWhatsNew": false}}"#)
        #expect(!off.updates.showWhatsNew)
        #expect(off.diagnostics.isEmpty)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"updates": {"notify": "loud", "checkIntervalSeconds": 5}}"#)
        #expect(snapshot.updates.notify == .badge)
        // Out-of-range numbers clamp, like every number setting.
        #expect(snapshot.updates.checkIntervalSeconds == UpdatesSettings.checkIntervalRange.lowerBound)
        #expect(snapshot.diagnostics.count == 2)
    }

    /// The Settings window, the React page and `cmux settings` edit these
    /// rows; their defaults are the parser's.
    @Test func everyKeyIsASchemaRowWithTheParsersDefault() {
        let defaults = UpdatesSettings()
        let expected: [String: JSONValue?] = [
            "updates.checkAutomatically": .bool(defaults.checkAutomatically),
            "updates.checkIntervalSeconds": .number(defaults.checkIntervalSeconds),
            "updates.downloadAutomatically": .bool(defaults.downloadAutomatically),
            "updates.installOnQuit": .bool(defaults.installOnQuit),
            "updates.notify": .string(defaults.notify.rawValue),
            "updates.showWhatsNew": .bool(defaults.showWhatsNew),
        ]
        for (key, value) in expected {
            let descriptor = SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init))
            #expect(descriptor != nil, "\(key) has no schema row")
            #expect(descriptor?.defaultValue == value, "\(key) default")
        }
    }

    /// Rollback keeps the newest N previous builds (default 1, 0 keeps none).
    @Test func keepPreviousVersions() throws {
        #expect(try parse("{}").updates.keepPreviousVersions == 1)
        #expect(try parse(#"{"updates": {"keepPreviousVersions": 3}}"#).updates.keepPreviousVersions == 3)
        #expect(try parse(#"{"updates": {"keepPreviousVersions": 0}}"#).updates.keepPreviousVersions == 0)
        let clamped = try parse(#"{"updates": {"keepPreviousVersions": 9}}"#)
        #expect(clamped.updates.keepPreviousVersions == 5)
        #expect(clamped.diagnostics.count == 1)
        let descriptor = SettingsSchema.descriptor(for: UpdatesSettings.keepPreviousVersionsPath)
        #expect(descriptor?.defaultValue == .number(1))
    }

    /// R114 metered networks: three choices, Low Data Mode by default.
    @Test func meteredNetwork() throws {
        #expect(try parse("{}").updates.meteredNetwork == .deferLowData)
        for value in UpdatesMeteredSetting.allCases {
            #expect(try parse(#"{"updates": {"meteredNetwork": "\#(value.rawValue)"}}"#).updates.meteredNetwork == value)
        }
        let bad = try parse(#"{"updates": {"meteredNetwork": "sometimes"}}"#)
        #expect(bad.updates.meteredNetwork == .deferLowData)
        #expect(bad.diagnostics.map(\.path) == ["updates.meteredNetwork"])
    }
}
