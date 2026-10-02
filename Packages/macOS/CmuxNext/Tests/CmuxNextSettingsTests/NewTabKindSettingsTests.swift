import CmuxNextSettings
import Foundation
import Testing

/// `tabs.newTabKind`: what Cmd-T and + open. "same-kind" unless the file
/// says otherwise; a bad value keeps "same-kind" with a diagnostic. The
/// Settings window and the new tab page's "default" toggle edit it.
@Suite struct NewTabKindSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToTheSameKind() throws {
        #expect(try parse("{}").newTabKind == .sameKind)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryChoice() throws {
        for kind in NewTabDefaultKind.allCases {
            let snapshot = try parse(#"{"tabs": {"newTabKind": "\#(kind.rawValue)"}}"#)
            #expect(snapshot.newTabKind == kind)
            #expect(snapshot.diagnostics.isEmpty)
        }
    }

    @Test func badValuesKeepTheSameKindWithADiagnostic() throws {
        let snapshot = try parse(#"{"tabs": {"newTabKind": "spreadsheet"}}"#)
        #expect(snapshot.newTabKind == .sameKind)
        #expect(snapshot.diagnostics.map(\.path) == ["tabs.newTabKind"])
    }

    @Test func theSchemaOffersEveryChoice() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabDefaultKind.configPath))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tabs.newTabKind is not a choice")
            return
        }
        #expect(choices.map(\.value) == NewTabDefaultKind.allCases.map(\.rawValue))
        #expect(descriptor.defaultValue == .string("same-kind"))
    }
}
