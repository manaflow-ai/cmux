import CmuxNextSettings
import Foundation
import Testing

/// R114: `updates.*` has great defaults (check, download and install on
/// quit all on, hourly checks, the card) and every step is customizable.
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
        #expect(snapshot.updates.notify == .card)
        #expect(snapshot.updates.quietHours == nil)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryKey() throws {
        let snapshot = try parse(#"""
        {"updates": {"checkAutomatically": false, "checkIntervalSeconds": 86400, "downloadAutomatically": false,
                     "installOnQuit": false, "notify": "silent", "quietHours": {"start": "22:00", "end": "07:30"}}}
        """#)
        #expect(!snapshot.updates.checkAutomatically)
        #expect(snapshot.updates.checkIntervalSeconds == 86400)
        #expect(!snapshot.updates.downloadAutomatically)
        #expect(!snapshot.updates.installOnQuit)
        #expect(snapshot.updates.notify == .silent)
        #expect(snapshot.updates.quietHours == QuietHours(start: 22 * 60, end: 7 * 60 + 30))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"updates": {"notify": "loud", "checkIntervalSeconds": 5, "quietHours": "night"}}"#)
        #expect(snapshot.updates.notify == .card)
        // Out-of-range numbers clamp, like every number setting.
        #expect(snapshot.updates.checkIntervalSeconds == UpdatesSettings.checkIntervalRange.lowerBound)
        #expect(snapshot.updates.quietHours == nil)
        #expect(snapshot.diagnostics.count == 3)
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
            "updates.quietHours": nil,
        ]
        for (key, value) in expected {
            let descriptor = SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init))
            #expect(descriptor != nil, "\(key) has no schema row")
            #expect(descriptor?.defaultValue == value, "\(key) default")
        }
    }
}
