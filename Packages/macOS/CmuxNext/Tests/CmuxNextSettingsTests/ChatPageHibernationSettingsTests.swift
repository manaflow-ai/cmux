@testable import CmuxNextSettings
import Foundation
import Testing

struct ChatPageHibernationSettingsTests {
    private func parse(_ json: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONValue.parse(Data(json.utf8)), validDensities: [], validMetrics: [])
    }

    @Test func theSharedDefaultsAreFiveMinutesAndTwoWarmNewTabs() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.chatPageHibernation == ChatPageHibernationSettings(enabled: true, hiddenMinutes: 5, newTabCapacity: 2))
        #expect(!snapshot.browserHibernation.discardsAutomatically, "website pages retain their existing default")
        for (path, value) in [(ChatPageHibernationSettings.enabledPath, JSONValue.bool(true)),
                              (ChatPageHibernationSettings.hiddenMinutesPath, .number(5)),
                              (ChatPageHibernationSettings.newTabCapacityPath, .number(2))] {
            #expect(try #require(SettingsSchema.descriptor(for: path)).defaultValue == value)
        }
    }

    @Test func configCanDisableOrTuneThePolicyWithoutChangingBrowserTabs() throws {
        let snapshot = try parse(#"{"agents":{"chatPages":{"enabled":false,"hiddenMinutes":12,"newTabCapacity":0}}}"#)
        #expect(snapshot.chatPageHibernation == ChatPageHibernationSettings(enabled: false, hiddenMinutes: 12, newTabCapacity: 0))
        #expect(!snapshot.browserHibernation.discardsAutomatically)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidValuesAreDiagnosedAndBounded() throws {
        let snapshot = try parse(#"{"agents":{"chatPages":{"enabled":"yes","hiddenMinutes":-1,"newTabCapacity":99}}}"#)
        #expect(snapshot.chatPageHibernation.enabled)
        #expect(snapshot.chatPageHibernation.hiddenMinutes == 1)
        #expect(snapshot.chatPageHibernation.newTabCapacity == 16)
        #expect(snapshot.diagnostics.filter { $0.path.hasPrefix("agents.chatPages") }.count == 3)
    }
}
