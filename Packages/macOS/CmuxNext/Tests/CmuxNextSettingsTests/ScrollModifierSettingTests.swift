import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.scrollModifier` (Lawrence 2026-10-24): `command` by default, so Command + scroll moves
/// columns and rows and a plain scroll goes to the pane; `none` restores the rule before it; a bad
/// value keeps `command` with a diagnostic; Settings lists both choices.
struct ScrollModifierSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["scrollModifier": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func commandByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.layoutScrollModifier == .command)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.scrollModifier" })
    }

    @Test func theUserCanPickEitherRule() {
        #expect(Self.parse(.string("none")).layoutScrollModifier == .noModifier)
        #expect(Self.parse(.string("command")).layoutScrollModifier == .command)
    }

    @Test func aBadValueKeepsCommandAndSaysWhy() {
        for value: JSONValue in [.string("option"), .bool(true)] {
            let snapshot = Self.parse(value)
            #expect(snapshot.layoutScrollModifier == .command)
            #expect(snapshot.diagnostics.contains { $0.path == "layout.scrollModifier" }, "\(snapshot.diagnostics)")
        }
    }

    @Test func settingsListsBothChoicesWithCommandTheDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "scrollModifier"]))
        #expect(descriptor.defaultValue == .string("command"))
        guard case let .choice(choices) = descriptor.kind else {
            Issue.record("not a choice: \(descriptor.kind)")
            return
        }
        #expect(choices.map(\.value) == ["command", "none"])
    }
}
