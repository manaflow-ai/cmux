import CmuxNextSettings
import Testing

struct IMessageSettingTests {
    private func parse(_ values: [String: JSONValue] = [:]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["imessage": .object(values)]), validDensities: [], validMetrics: [])
    }

    @Test func onlyAnExplicitBooleanEnablesTheConnector() {
        #expect(!parse().imessageEnabled)
        #expect(parse(["enabled": .bool(true)]).imessageEnabled)
        #expect(!parse(["enabled": .bool(false)]).imessageEnabled)
        for value in [JSONValue.string("true"), .number(1), .null, .array([]), .object([:])] {
            let snapshot = parse(["enabled": value])
            #expect(!snapshot.imessageEnabled)
            #expect(snapshot.diagnostics.contains { $0.path == "imessage.enabled" })
        }
    }

    @Test func skippingAutomationDoesNotOptIn() {
        let snapshot = parse(["automationSkipped": .bool(true)])
        #expect(snapshot.imessageAutomationSkipped)
        #expect(!snapshot.imessageEnabled)
        #expect(!parse(["automationSkipped": .string("true")]).imessageAutomationSkipped)
    }

    @Test func connectorChoicesStayOutOfSettingsAndThePalette() throws {
        for path in [CmuxConfigSnapshot.imessageEnabledPath, CmuxConfigSnapshot.imessageAutomationSkippedPath] {
            let descriptor = try #require(SettingsSchema.descriptor(for: path))
            #expect(descriptor.defaultValue == .bool(false))
            #expect(!descriptor.isShownOnSettingsPage)
            #expect(!descriptor.isPaletteExposed)
            #expect(SettingsSchema.agentSettable(descriptor) == false)
        }
    }
}
