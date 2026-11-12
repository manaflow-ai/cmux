@testable import CmuxNextSettings
import Testing

/// `agentPane.dictationSource` and `agentPane.dictationShortcut`: what the composer's mic dictates
/// with, cmux's own dictation (the default, unchanged) or the dictation app the person already uses,
/// and the chord the mic sends to it. Leo, 2026-11-07: "you can optionally have it be like, oh, you
/// use Claude's thing, or ChatGPT's thing ... Or, like, maybe you can map the button to that thing".
struct AgentPaneDictationSourceSettingTests {
    @Test func cmuxByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationSource == .cmux)
        #expect(snapshot.agentPaneComposer.dictationShortcut == "")
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["dictationSource"])?.stringValue == "cmux")
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["dictationShortcut"])?.stringValue == "")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.dictationSourcePath)
        #expect(row?.defaultValue == .string("cmux"))
        #expect(row?.isPaletteExposed == true)
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.dictationSource"))
        // The chord cmux posts into another app is the person's alone.
        #expect(!SettingsSchema.agentSettableKeys.contains("agentPane.dictationShortcut"))
    }

    @Test func eachSourceRoundTrips() {
        for source in AgentPaneDictationSource.allCases {
            let root = JSONValue.object(["agentPane": .object(["dictationSource": .string(source.rawValue)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.dictationSource == source)
            #expect(snapshot.agentPaneComposer.pageValue.value(at: ["dictationSource"])?.stringValue == source.rawValue)
            #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.dictationSource" })
        }
    }

    @Test func aBadSourceIsCmuxWithADiagnostic() {
        for bad: JSONValue in [.string("ChatGPT"), .string("wispr"), .bool(true), .number(1)] {
            let root = JSONValue.object(["agentPane": .object(["dictationSource": bad, "showDictation": .bool(false)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.dictationSource == .cmux)
            #expect(snapshot.agentPaneComposer.showDictation == false)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.dictationSource" })
        }
    }

    @Test(arguments: ["ctrl+opt+space", "cmd+shift+d", "Option+Space", "ctrl+f5", ""])
    func aChordIsKept(_ chord: String) {
        let root = JSONValue.object(["agentPane": .object(["dictationShortcut": .string(chord)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationShortcut == chord)
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.dictationShortcut" })
    }

    /// A bare key, shift alone, an unknown key or a repeated modifier would type into the composer
    /// or nowhere: refused with a diagnostic, and kept, so the mic refuses it rather than sending the
    /// app's default chord the person meant to replace.
    @Test(arguments: ["space", "shift+a", "ctrl+", "ctrl+ctrl+a", "hyper+a", "ctrl+opt+escape", "fn"])
    func aBadChordIsRefusedWithADiagnostic(_ chord: String) {
        #expect(AgentPaneDictationShortcut(chord) == nil)
        let root = JSONValue.object(["agentPane": .object(["dictationShortcut": .string(chord)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.dictationShortcut == chord)
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.dictationShortcut" })
    }

    @Test func aChordReadsItsModifiersAndKey() {
        let chord = AgentPaneDictationShortcut("Ctrl + Opt + Space")
        #expect(chord?.modifiers == [.control, .option])
        #expect(chord?.key == "space")
    }

    @Test func sitsAfterShowDictationOnTheSettingsPage() {
        // The Message Box card sits on Settings > Chat (settings overhaul, 2026-11-07).
        let keys = SettingsPageLayout.specs.first { $0.id == "chat" }?.groups.flatMap(\.keys) ?? []
        let show = keys.firstIndex(of: "agentPane.showDictation")
        #expect(show != nil && keys.firstIndex(of: "agentPane.dictationSource") == show.map { $0 + 1 })
        #expect(show != nil && keys.firstIndex(of: "agentPane.dictationShortcut") == show.map { $0 + 2 })
    }
}
