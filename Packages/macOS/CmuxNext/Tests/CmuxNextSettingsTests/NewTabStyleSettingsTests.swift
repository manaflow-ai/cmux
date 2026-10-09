import CmuxNextSettings
import Foundation
import Testing

/// `newTab.style` selects the page design shown before the user starts a chat.
@Suite struct NewTabStyleSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func theSchemaOffersTheFirstTwoPageStyles() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["newTab", "style"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("newTab.style is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["cmux", "classic"])
        #expect(descriptor.defaultValue == .string("cmux"))
    }

    @Test func anInvalidStyleIsReportedAtItsConfigPath() throws {
        let snapshot = try parse(#"{"newTab": {"style": "spreadsheet"}}"#)
        #expect(snapshot.diagnostics.map(\.path) == ["newTab.style"])
    }
}
