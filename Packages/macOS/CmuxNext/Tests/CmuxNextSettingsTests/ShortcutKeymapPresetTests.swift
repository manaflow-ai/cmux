import CmuxNextSettings
import Testing

/// Base keymap presets: what switching cmux.json to one writes, removes and
/// keeps, as the old app's picker planned it.
struct ShortcutKeymapPresetTests {
    /// cmux.json after writing `plan` over `bindings`.
    static func applying(_ plan: ShortcutKeymapPlan, to bindings: [String: JSONValue]) -> [String: JSONValue] {
        var result = bindings
        for change in plan.changes { result[change.actionID] = change.write }
        return result
    }

    @Test func everyPresetValueParsesAndTmuxChordsStartWithCtrlB() {
        for preset in ShortcutKeymapPreset.allCases {
            for (id, value) in preset.overrides {
                let binding = ShortcutBindingFormat.parse(value)
                #expect(binding != nil, "\(preset) \(id)")
                if case .chord(let first, _)? = binding {
                    #expect(first == ShortcutStrokeSpec(key: "b", control: true), "\(preset) \(id)")
                }
            }
        }
        #expect(ShortcutKeymapPreset.cmux.overrides.isEmpty)
    }

    @Test func anEmptyFileTakesEveryOverride() {
        let plan = ShortcutKeymapPreset.tmux.plan(from: [:])
        #expect(plan.changes.count == ShortcutKeymapPreset.tmux.overrides.count)
        #expect(plan.changes.first == .init(actionID: "newTab", write: ["ctrl+b", "c"]))
        #expect(plan.kept.isEmpty)
        #expect(ShortcutKeymapPreset.active(in: Self.applying(plan, to: [:])) == .tmux)
        #expect(ShortcutKeymapPreset.tmux.plan(from: Self.applying(plan, to: [:])).isEmpty)
    }

    /// From tmux to iTerm2: tmux's bindings go, iTerm2's come, and the one
    /// both set (selectWorkspaceByNumber) is replaced.
    @Test func switchingPresetsReplacesWhatAPresetWrote() {
        let tmux = Self.applying(ShortcutKeymapPreset.tmux.plan(from: [:]), to: [:])
        let plan = ShortcutKeymapPreset.iTerm2.plan(from: tmux)
        let after = Self.applying(plan, to: tmux)
        #expect(after["newTab"] == nil)
        #expect(after["selectWorkspaceByNumber"] == "cmd+opt+1")
        #expect(after["selectSurfaceByNumber"] == "cmd+1")
        #expect(ShortcutKeymapPreset.active(in: after) == .iTerm2)

        let back = Self.applying(ShortcutKeymapPreset.cmux.plan(from: after), to: after)
        #expect(back.isEmpty)
        #expect(ShortcutKeymapPreset.active(in: back) == .cmux)
    }

    @Test func aBindingSetByHandStays() {
        let bindings: [String: JSONValue] = ["newTab": "cmd+k", "splitRight": ["ctrl+a", "|"]]
        let plan = ShortcutKeymapPreset.tmux.plan(from: bindings)
        #expect(plan.kept == ["newTab", "splitRight"])
        #expect(!plan.changes.contains { $0.actionID == "newTab" || $0.actionID == "splitRight" })
        #expect(ShortcutKeymapPreset.cmux.plan(from: bindings).isEmpty, "cmux removes only what a preset wrote")
        #expect(ShortcutKeymapPreset.active(in: bindings) == .cmux)
        let mixed = bindings.merging(["closeOtherTabsInPane": "cmd+opt+w", "closeTab": ["ctrl+b", "x"]]) { $1 }
        #expect(ShortcutKeymapPreset.active(in: mixed) == nil, "Terminal.app and tmux bindings together")
    }

    /// An equivalent spelling of a preset's value counts as the preset's.
    @Test func ownershipComparesParsedBindings() {
        let plan = ShortcutKeymapPreset.cmux.plan(from: ["renameTab": "shift+cmd+i"])
        #expect(plan.changes == [.init(actionID: "renameTab", write: nil)])
    }
}
