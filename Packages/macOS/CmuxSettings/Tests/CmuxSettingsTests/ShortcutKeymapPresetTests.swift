import Foundation
import Testing

@testable import CmuxSettings

@Suite("Shortcut keymap presets")
struct ShortcutKeymapPresetTests {
    private func snapshot(_ bindings: [ShortcutAction: StoredShortcut]) -> ShortcutBindingsSnapshot {
        ShortcutBindingsSnapshot(
            bindings: Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }),
            managedActionIDs: Set(bindings.keys.map(\.rawValue))
        )
    }

    private func applied(_ preset: ShortcutKeymapPreset) -> [ShortcutAction: StoredShortcut] {
        preset.overrides.compactMapValues(\.shortcut)
    }

    private let empty = ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: [])

    @Test(arguments: ShortcutKeymapPreset.allCases)
    func everyOverrideIsValidAndDiffersFromTheDefault(preset: ShortcutKeymapPreset) throws {
        for (action, binding) in preset.overrides {
            let shortcut = try #require(binding.shortcut, "\(preset) \(action) does not parse")
            #expect(action.shortcutBindingPolicyResult(for: shortcut) == .accepted, "\(preset) \(action)")
            #expect(shortcut != action.defaultShortcut?.canonicalized(), "\(preset) \(action) repeats the default")
        }
    }

    @Test func cmuxPresetWritesNothing() {
        #expect(ShortcutKeymapPreset.cmux.overrides.isEmpty)
        #expect(ShortcutKeymapPreset.cmux.plan(from: empty).isEmpty)
    }

    @Test func applyingToDefaultsWritesOnlyThePresetOverrides() throws {
        let plan = ShortcutKeymapPreset.iTerm2.plan(from: empty)

        #expect(Set(plan.changes.map(\.action)) == Set(ShortcutKeymapPreset.iTerm2.overrides.keys))
        #expect(plan.kept.isEmpty)
        let copyMode = try #require(plan.changes.first { $0.action == .toggleTerminalCopyMode })
        #expect(copyMode.write == .stroke("cmd+shift+c"))
        #expect(copyMode.before == StoredShortcut(first: ShortcutStroke(key: "m", command: true, shift: true)))
        #expect(copyMode.after == StoredShortcut(first: ShortcutStroke(key: "c", command: true, shift: true)))
    }

    @Test(arguments: ShortcutKeymapPreset.allCases.filter { $0 != .cmux })
    func switchingBackToCmuxRemovesEveryOverride(preset: ShortcutKeymapPreset) {
        let plan = ShortcutKeymapPreset.cmux.plan(from: snapshot(applied(preset)))

        #expect(Set(plan.changes.map(\.action)) == Set(preset.overrides.keys))
        #expect(plan.changes.allSatisfy { $0.write == nil })
        #expect(plan.changes.allSatisfy { $0.after == ($0.action.defaultShortcut ?? .unbound) })
    }

    @Test func switchingPresetsReplacesTheOtherPresetsValues() throws {
        let plan = ShortcutKeymapPreset.tmux.plan(from: snapshot(applied(.iTerm2)))

        let copyMode = try #require(plan.changes.first { $0.action == .toggleTerminalCopyMode })
        #expect(copyMode.before == ShortcutKeymapBinding.stroke("cmd+shift+c").shortcut)
        #expect(copyMode.write == .chord("ctrl+b", "["))
        let resize = try #require(plan.changes.first { $0.action == .resizePaneLeft })
        #expect(resize.write == nil)
        #expect(plan.changes.contains { $0.action == .selectSurfaceByNumber && $0.write == nil })
        #expect(plan.changes.contains { $0.action == .newTab && $0.write == .chord("ctrl+b", "c") })
    }

    @Test func userBindingsSurviveEveryPreset() {
        let custom = StoredShortcut(first: ShortcutStroke(key: "x", command: true, shift: true))
        let unrelated = StoredShortcut(first: ShortcutStroke(key: "k", command: true, option: true))
        var bindings = applied(.iTerm2)
        bindings[.toggleTerminalCopyMode] = custom
        bindings[.openFolder] = unrelated

        let toTmux = ShortcutKeymapPreset.tmux.plan(from: snapshot(bindings))
        #expect(toTmux.kept.contains(.toggleTerminalCopyMode))
        #expect(!toTmux.changes.contains { $0.action == .toggleTerminalCopyMode || $0.action == .openFolder })

        let toCmux = ShortcutKeymapPreset.cmux.plan(from: snapshot(bindings))
        #expect(!toCmux.changes.contains { $0.action == .toggleTerminalCopyMode || $0.action == .openFolder })
        #expect(toCmux.changes.contains { $0.action == .resizePaneLeft })
    }

    @Test func legacyUserDefaultsBindingsCountAsSetByHand() {
        let legacyCopyMode = StoredShortcut(first: ShortcutStroke(key: "x", command: true, shift: true))
        let legacy = [
            ShortcutAction.toggleTerminalCopyMode.rawValue: legacyCopyMode,
            ShortcutAction.resizePaneLeft.rawValue: ShortcutKeymapBinding.stroke("cmd+ctrl+left").shortcut!,
        ]

        let plan = ShortcutKeymapPreset.iTerm2.plan(from: empty, legacyBindings: legacy)

        #expect(plan.kept == [.toggleTerminalCopyMode])
        #expect(!plan.changes.contains { $0.action == .toggleTerminalCopyMode })
        // Already the preset's value, so there is nothing to write or keep.
        #expect(!plan.changes.contains { $0.action == .resizePaneLeft })
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.iTerm2)), legacyBindings: legacy) == .iTerm2)
    }

    @Test func removingAPresetOverrideRevealsTheLegacyBinding() throws {
        let legacyCopyMode = StoredShortcut(first: ShortcutStroke(key: "x", command: true, shift: true))

        let plan = ShortcutKeymapPreset.cmux.plan(
            from: snapshot(applied(.iTerm2)),
            legacyBindings: [ShortcutAction.toggleTerminalCopyMode.rawValue: legacyCopyMode]
        )

        let copyMode = try #require(plan.changes.first { $0.action == .toggleTerminalCopyMode })
        #expect(copyMode.write == nil)
        #expect(copyMode.after == legacyCopyMode)
    }

    @Test func handTypedPresetValueIsTreatedAsPresetOwned() {
        // Ownership is inferred from values, so a hand-typed binding equal to
        // a preset's value is removed when switching back to cmux.
        let typed = snapshot([.toggleTerminalCopyMode: ShortcutKeymapBinding.stroke("cmd+shift+c").shortcut!])

        let plan = ShortcutKeymapPreset.cmux.plan(from: typed)

        #expect(plan.changes.map(\.action) == [.toggleTerminalCopyMode])
    }

    @Test func malformedManagedBindingCountsAsACustomization() {
        let managed = ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: ["toggleTerminalCopyMode"])

        let plan = ShortcutKeymapPreset.iTerm2.plan(from: managed)

        #expect(plan.kept == [.toggleTerminalCopyMode])
    }

    @Test func activePresetFollowsTheFile() {
        #expect(ShortcutKeymapPreset.active(in: empty) == .cmux)
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.iTerm2))) == .iTerm2)
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.tmux))) == .tmux)

        var customized = applied(.iTerm2)
        customized[.toggleTerminalCopyMode] = StoredShortcut(first: ShortcutStroke(key: "x", command: true, shift: true))
        #expect(ShortcutKeymapPreset.active(in: snapshot(customized)) == .iTerm2)

        var mixed = applied(.terminal)
        mixed[.resizePaneLeft] = ShortcutKeymapBinding.stroke("cmd+ctrl+left").shortcut
        #expect(ShortcutKeymapPreset.active(in: snapshot(mixed)) == nil)
    }

    @Test(arguments: ShortcutKeymapPreset.allCases)
    func presetsIntroduceNoCmuxConflicts(preset: ShortcutKeymapPreset) {
        var effective: [ShortcutAction: StoredShortcut] = [:]
        for action in ShortcutAction.allCases {
            effective[action] = action.defaultShortcut
        }
        for (action, shortcut) in applied(preset) {
            effective[action] = shortcut
        }

        for overridden in preset.overrides.keys {
            guard let shortcut = effective[overridden] else { continue }
            for (other, otherShortcut) in effective where other != overridden {
                guard Self.overlaps(shortcut, overridden, otherShortcut, other) else { continue }
                let collides = ShortcutWhenClause.bindingsCollide(
                    overridden.defaultFocusWhenClause,
                    lhsHasPriority: overridden.hasPriorityShortcutRouting,
                    other.defaultFocusWhenClause,
                    rhsHasPriority: other.hasPriorityShortcutRouting
                )
                #expect(!collides, "\(preset): \(overridden) collides with \(other)")
            }
        }
    }

    @Test(arguments: ShortcutKeymapPreset.allCases)
    func presetsShipWithoutMacOSConflicts(preset: ShortcutKeymapPreset) {
        #expect(preset.plan(from: empty).systemConflicts.isEmpty)
    }

    @Test func browserPresetBindsTheTabKeysAndTheNumberRow() throws {
        let plan = ShortcutKeymapPreset.browser.plan(from: empty)

        #expect(Set(plan.changes.map(\.action)) == [
            .nextSurface, .prevSurface, .selectSurfaceByNumber, .selectWorkspaceByNumber,
        ])
        let next = try #require(plan.changes.first { $0.action == .nextSurface })
        #expect(next.before == StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true)))
        #expect(next.after == StoredShortcut(first: ShortcutStroke(key: "\t", control: true)))
        let previous = try #require(plan.changes.first { $0.action == .prevSurface })
        #expect(previous.after == StoredShortcut(first: ShortcutStroke(key: "\t", shift: true, control: true)))
        // Cmd-1…9 moves from workspaces to surfaces, so workspaces take the
        // Option row rather than losing the number row.
        let surfaces = try #require(plan.changes.first { $0.action == .selectSurfaceByNumber })
        #expect(surfaces.after == StoredShortcut(first: ShortcutStroke(key: "1", command: true)))
        let workspaces = try #require(plan.changes.first { $0.action == .selectWorkspaceByNumber })
        #expect(workspaces.after == StoredShortcut(first: ShortcutStroke(key: "1", command: true, option: true)))
    }

    @Test func browserPresetLeavesTheShortcutsABrowserAlreadyAgreesWith() {
        // Cmd-T, Cmd-W, Cmd-Shift-T, Cmd-L, Cmd-R, Cmd-F and Cmd-[ / Cmd-]
        // are cmux defaults already, so the preset must not write them.
        let untouched: [ShortcutAction: ShortcutStroke] = [
            .newSurface: ShortcutStroke(key: "t", command: true),
            .closeTab: ShortcutStroke(key: "w", command: true),
            .reopenClosedBrowserPanel: ShortcutStroke(key: "t", command: true, shift: true),
            .focusBrowserAddressBar: ShortcutStroke(key: "l", command: true),
            .browserReload: ShortcutStroke(key: "r", command: true),
            .find: ShortcutStroke(key: "f", command: true),
            .focusHistoryBack: ShortcutStroke(key: "[", command: true),
            .focusHistoryForward: ShortcutStroke(key: "]", command: true),
        ]

        for (action, expected) in untouched {
            #expect(ShortcutKeymapPreset.browser.overrides[action] == nil, "\(action)")
            #expect(
                action.defaultShortcut?.canonicalized() == StoredShortcut(first: expected).canonicalized(),
                "\(action) is no longer a browser-style default"
            )
        }
    }

    @Test func browserPresetIsDetectedAndReversible() {
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.browser))) == .browser)

        let back = ShortcutKeymapPreset.cmux.plan(from: snapshot(applied(.browser)))
        #expect(Set(back.changes.map(\.action)) == Set(ShortcutKeymapPreset.browser.overrides.keys))
        #expect(back.changes.allSatisfy { $0.write == nil })
    }

    /// Browser and iTerm2 write the same two numbered actions, so a file on one
    /// of them satisfies the other's number-row check. Detection has to come
    /// apart on the rest, in both directions, or picking a style in Settings
    /// would show the wrong one as current.
    @Test func browserAndITerm2AreNotMistakenForEachOther() {
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.browser))) == .browser)
        #expect(ShortcutKeymapPreset.active(in: snapshot(applied(.iTerm2))) == .iTerm2)
    }

    /// Switching between the two presets that share the number row has to land
    /// on exactly the target's override set, with nothing of the other left
    /// behind and the shared rows not rewritten on the way through.
    @Test func iTerm2RoundTripsThroughBrowser() throws {
        let start = snapshot(applied(.iTerm2))

        let toBrowser = ShortcutKeymapPreset.browser.plan(from: start)
        // The two numbered actions already hold the right values, so the plan
        // leaves them alone and only settles what the presets disagree about.
        #expect(!toBrowser.changes.contains { $0.action == .selectSurfaceByNumber })
        #expect(!toBrowser.changes.contains { $0.action == .selectWorkspaceByNumber })

        let asBrowser = try replaying(toBrowser, onto: applied(.iTerm2))
        #expect(asBrowser == applied(.browser))
        #expect(ShortcutKeymapPreset.active(in: snapshot(asBrowser)) == .browser)

        let back = ShortcutKeymapPreset.iTerm2.plan(from: snapshot(asBrowser))
        let asITerm2 = try replaying(back, onto: asBrowser)
        #expect(asITerm2 == applied(.iTerm2))
        #expect(ShortcutKeymapPreset.active(in: snapshot(asITerm2)) == .iTerm2)
    }

    /// Applies a plan's writes to a bindings dictionary the way the JSON store
    /// does, so the result can be compared against ``applied(_:)``.
    ///
    /// A plan writes the hand-editable ``ShortcutKeymapBinding`` form, while
    /// bindings compare as parsed ``StoredShortcut``, so each write is parsed
    /// on the way in. A write that does not parse would drop the key and read
    /// as "the preset does not override this action", which would make a round
    /// trip pass for the wrong reason, so that fails here instead.
    private func replaying(
        _ plan: ShortcutKeymapPlan,
        onto bindings: [ShortcutAction: StoredShortcut]
    ) throws -> [ShortcutAction: StoredShortcut] {
        var result = bindings
        for change in plan.changes {
            guard let write = change.write else {
                // No write means the override is removed and the cmux default
                // applies again.
                result[change.action] = nil
                continue
            }
            result[change.action] = try #require(
                write.shortcut,
                "\(plan.preset) writes an unparseable binding for \(change.action)"
            )
        }
        return result
    }

    /// Whether two bindings can fire on the same keystroke sequence. A chord
    /// overlaps a single stroke equal to its prefix; numbered actions stand for
    /// their `1…9` family.
    private static func overlaps(
        _ lhs: StoredShortcut,
        _ lhsAction: ShortcutAction,
        _ rhs: StoredShortcut,
        _ rhsAction: ShortcutAction
    ) -> Bool {
        guard !lhs.isUnbound, !rhs.isUnbound else { return false }
        return expanded(lhs, lhsAction).contains { left in
            expanded(rhs, rhsAction).contains { right in
                left.first == right.first
                    && (left.second == nil || right.second == nil || left.second == right.second)
            }
        }
    }

    private static func expanded(_ shortcut: StoredShortcut, _ action: ShortcutAction) -> [StoredShortcut] {
        let canonical = shortcut.canonicalized()
        guard action.usesNumberedDigitMatching else { return [canonical] }
        return (1...9).map { digit in
            let stroke = canonical.second ?? canonical.first
            let digitStroke = ShortcutStroke(
                key: String(digit),
                command: stroke.command,
                shift: stroke.shift,
                option: stroke.option,
                control: stroke.control
            )
            return canonical.second == nil
                ? StoredShortcut(first: digitStroke)
                : StoredShortcut(first: canonical.first, second: digitStroke)
        }
    }
}

@Suite("macOS system shortcut conflicts")
struct MacOSSystemShortcutTests {
    @Test func flagsASingleStrokeMacOSOwns() {
        let spotlight = StoredShortcut(first: ShortcutStroke(key: "space", command: true))
        #expect(MacOSSystemShortcut.conflicts(with: spotlight, for: .commandPalette) == [.spotlight])

        let dock = StoredShortcut(first: ShortcutStroke(key: "D", command: true, option: true))
        #expect(MacOSSystemShortcut.conflicts(with: dock, for: .splitBrowserRight) == [.toggleDockHiding])
    }

    @Test func ignoresShortcutsMacOSLeavesAlone() {
        let split = StoredShortcut(first: ShortcutStroke(key: "d", command: true))
        #expect(MacOSSystemShortcut.conflicts(with: split, for: .splitRight).isEmpty)
        #expect(MacOSSystemShortcut.conflicts(with: .unbound, for: .splitRight).isEmpty)
    }

    @Test func checksBothStrokesOfAChord() {
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "←", control: true)
        )
        #expect(MacOSSystemShortcut.conflicts(with: chord, for: .focusLeft) == [.spaceLeft])
    }

    @Test func expandsNumberedActionsToTheirDigitFamily() {
        let family = StoredShortcut(first: ShortcutStroke(key: "1", command: true, shift: true))

        #expect(MacOSSystemShortcut.conflicts(with: family, for: .selectWorkspaceByNumber)
            == [.screenshotScreen, .screenshotSelection, .screenshotToolbar])
        #expect(MacOSSystemShortcut.conflicts(with: family, for: .openFolder).isEmpty)
    }
}

@Suite("Keymap presets written through JSONConfigStore")
struct ShortcutKeymapStoreTests {
    @Test func applyWritesReadableOverridesAndSwitchingBackRemovesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cmux.json")
        try Data("""
        {
          // keep this comment
          "app": { "appearance": "dark" },
          "shortcuts": { "bindings": { "openFolder": "cmd+opt+k" } }
        }

        """.utf8).write(to: file)
        let store = JSONConfigStore(fileURL: file)
        let bindingsKey = SettingCatalog().shortcuts.bindingSnapshot

        let toTmux = ShortcutKeymapPreset.tmux.plan(from: await store.value(for: bindingsKey))
        try await store.applyShortcutKeymap(toTmux)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("// keep this comment"))
        #expect(text.contains("\"ctrl+b\""))
        let afterTmux = await store.value(for: bindingsKey)
        #expect(ShortcutKeymapPreset.active(in: afterTmux) == .tmux)
        #expect(afterTmux.bindings["openFolder"] == ShortcutKeymapBinding.stroke("cmd+opt+k").shortcut)

        try await store.applyShortcutKeymap(ShortcutKeymapPreset.cmux.plan(from: afterTmux))

        let afterCmux = await store.value(for: bindingsKey)
        #expect(afterCmux.managedActionIDs == ["openFolder"])
        #expect(ShortcutKeymapPreset.active(in: afterCmux) == .cmux)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"appearance\""))
    }
}
