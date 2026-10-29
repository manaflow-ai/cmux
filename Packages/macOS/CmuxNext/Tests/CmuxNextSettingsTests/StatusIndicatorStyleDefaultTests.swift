import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Leo: "just leave it as an option. just dont make it the default."
struct StatusIndicatorStyleDefaultTests {
    @Test func thinArcIsTheDefaultAndPulsingDotRemainsSelectable() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["appearance", "statusIndicator", "style"]))
        #expect(row.defaultValue == .string("arc"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("Loading Indicator Style must offer choices")
            return
        }
        #expect(choices.map(\.value).contains("dot"))
        for value in [nil, "dot"] as [String?] {
            let indicator: JSONValue = .object(value.map { ["style": .string($0)] } ?? [:])
            let snapshot = CmuxConfigSnapshot.parse(
                .object(["appearance": .object(["statusIndicator": indicator])]),
                validDensities: [], validMetrics: [])
            #expect(snapshot.statusIndicator.style == (value == nil ? .arc : .dot))
            #expect(snapshot.diagnostics.isEmpty)
        }
    }
}
