import CmuxNextSettings
import Foundation
import Testing

/// `tasks.layout` (plans/cmux-next/tasks.md decision T2): "inbox" unless
/// the file says otherwise; a bad value keeps "inbox" with a diagnostic.
/// The Settings window edits it; the Tasks pane follows it live.
@Suite struct TasksLayoutSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToInbox() throws {
        #expect(try parse("{}").tasksLayout == .inbox)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryChoice() throws {
        for layout in TasksLayoutPreference.allCases {
            let snapshot = try parse(#"{"tasks": {"layout": "\#(layout.rawValue)"}}"#)
            #expect(snapshot.tasksLayout == layout)
            #expect(snapshot.diagnostics.isEmpty)
        }
    }

    @Test func badValuesKeepInboxWithADiagnostic() throws {
        let snapshot = try parse(#"{"tasks": {"layout": "spreadsheet"}}"#)
        #expect(snapshot.tasksLayout == .inbox)
        #expect(snapshot.diagnostics.map(\.path) == ["tasks.layout"])
    }

    @Test func theSchemaOffersEveryChoiceWithTheDocumentedDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: TasksLayoutSetting().configPath))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tasks.layout is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["list", "board", "inbox"])
        #expect(descriptor.defaultValue == .string("inbox"))
        #expect(descriptor.section == .general)
    }
}
