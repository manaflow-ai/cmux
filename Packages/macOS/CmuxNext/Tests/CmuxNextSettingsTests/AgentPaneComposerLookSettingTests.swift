import CmuxNextSettings
import Testing

/// `agentPane.composerLook` (auto, studio) and `agentPane.emptyChatComposerPosition` (bottom,
/// center): the composer's look and where an empty chat's composer sits, settings a profile can
/// carry. Both reach the page on the `composer` event (webviews composerSettings.ts, composerLook.ts)
/// and default to the page's own behaviour: the app's own composer, docked at the bottom.
struct AgentPaneComposerLookSettingTests {
    @Test func defaultsKeepTodaysBehaviour() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.composerLook == .auto)
        #expect(snapshot.agentPaneComposer.emptyChatComposerPosition == .bottom)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerLook"])?.stringValue == "auto")
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["emptyChatComposerPosition"])?.stringValue == "bottom")
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.composerLookPath)?.defaultValue == .string("auto"))
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.emptyChatComposerPositionPath)?.defaultValue == .string("bottom"))
    }

    @Test func setValuesRoundTrip() {
        for look in ["studio"] {
            let root = JSONValue.object([
                "agentPane": .object(["composerLook": .string(look), "emptyChatComposerPosition": .string("center")]),
            ])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.composerLook.rawValue == look)
            #expect(snapshot.agentPaneComposer.emptyChatComposerPosition == .center)
            #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerLook"])?.stringValue == look)
            #expect(snapshot.agentPaneComposer.pageValue.value(at: ["emptyChatComposerPosition"])?.stringValue == "center")
            #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agentPane.") })
        }
    }

    /// A profile's settings travel only when an agent may set them (cmux-customize profile.rs).
    @Test func agentsMaySetThem() {
        for key in ["agentPane.composerLook", "agentPane.emptyChatComposerPosition"] {
            #expect(SettingsSchema.agentSettableKeys.contains(key))
            #expect(SettingsSchema.agentRefusedKeys[key] == nil)
        }
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() {
        for bad: JSONValue in [.string("Studio"), .string("codex"), .string("claude"), .bool(true)] {
            let root = JSONValue.object([
                "agentPane": .object(["composerLook": bad, "emptyChatComposerPosition": bad]),
            ])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.composerLook == .auto)
            #expect(snapshot.agentPaneComposer.emptyChatComposerPosition == .bottom)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.composerLook" })
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.emptyChatComposerPosition" })
        }
    }
}
