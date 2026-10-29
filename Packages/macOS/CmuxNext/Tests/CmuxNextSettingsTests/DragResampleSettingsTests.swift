@testable import CmuxNextSettings
import Testing

/// `input.resampleDrags` and `input.resampleFrameAheadMs` (``DragResampleSettings``): on and 0
/// by default, invalid values fall back, and both rows are in the schema, off the page while the
/// `resampledDrags` feature is off, and settable by agents (looks only).
struct DragResampleSettingsTests {
    static func root(_ input: [String: JSONValue]) -> JSONValue { .object(["input": .object(input)]) }

    @Test func defaultsAreOnWithNoPrediction() {
        let settings = DragResampleSettings(.object([:]))
        #expect(settings.resampleDrags)
        #expect(settings.frameAheadMs == 0)
    }

    @Test func valuesRead() {
        let settings = DragResampleSettings(Self.root(["resampleDrags": .bool(false), "resampleFrameAheadMs": .number(8)]))
        #expect(!settings.resampleDrags)
        #expect(settings.frameAheadMs == 8)
    }

    @Test func invalidValuesFallBack() {
        let wrongTypes = DragResampleSettings(Self.root(["resampleDrags": .string("yes"), "resampleFrameAheadMs": .string("8")]))
        #expect(wrongTypes.resampleDrags)
        #expect(wrongTypes.frameAheadMs == 0)
        #expect(DragResampleSettings(Self.root(["resampleFrameAheadMs": .number(40)])).frameAheadMs == 0)
        #expect(DragResampleSettings(Self.root(["resampleFrameAheadMs": .number(-1)])).frameAheadMs == 0)
    }

    @Test func theSchemaRowsMatchTheDefaults() throws {
        let toggle = try #require(SettingsSchema.all.first { $0.id == "input.resampleDrags" })
        #expect(toggle.kind == .toggle)
        #expect(toggle.defaultValue == .bool(DragResampleSettings.resampleDragsDefault))
        #expect(!toggle.isShownOnSettingsPage, "behind the resampledDrags feature")
        let ahead = try #require(SettingsSchema.all.first { $0.id == "input.resampleFrameAheadMs" })
        #expect(ahead.defaultValue == .number(DragResampleSettings.frameAheadDefault))
        guard case .number(let number) = ahead.kind else {
            Issue.record("input.resampleFrameAheadMs is not a number row")
            return
        }
        #expect(number.range == DragResampleSettings.frameAheadRange)
        #expect(!ahead.isShownOnSettingsPage)
    }

    @Test func agentsMaySetThem() {
        for key in ["input.resampleDrags", "input.resampleFrameAheadMs"] {
            #expect(SettingsSchema.agentSettableKeys.contains(key))
            #expect(SettingsSchema.agentRefusedKeys[key] == nil)
        }
    }
}
