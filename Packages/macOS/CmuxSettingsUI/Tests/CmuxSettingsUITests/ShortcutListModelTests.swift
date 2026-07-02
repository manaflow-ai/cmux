// Tests/CmuxSettingsUITests/ShortcutListModelTests.swift
import Foundation
import Testing
import CmuxSettings
@testable import CmuxSettingsUI

/// Behavior tests for ``ShortcutListModel``.
@MainActor
@Suite struct ShortcutListModelTests {

    private func makeStore() -> (JSONConfigStore, SettingCatalog, SettingsErrorLog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json")
        return (JSONConfigStore(fileURL: fileURL), SettingCatalog(), SettingsErrorLog())
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    @Test func conflictingStrokeIsRejectedNotWritten() async throws {
        // WHY: legacy never persists a conflicting binding; the conflict must
        // be a purely in-memory rejection so Undo rolls back with no disk write.
        let (store, catalog, errorLog) = makeStore()
        let conflictAction = ShortcutAction.closeWindow
        let targetAction = ShortcutAction.openSettings
        let conflictStroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false)
        let conflictShortcut = StoredShortcut(first: conflictStroke)

        // Pre-load closeWindow with ⌘Q
        try await store.set([conflictAction.rawValue: conflictShortcut], for: catalog.shortcuts.bindings)

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await spin(until: { model.bindings[conflictAction.rawValue] != nil })

        // Attempt to steal ⌘Q for openSettings → should conflict
        await model.assign(stroke: conflictStroke, to: targetAction)

        // Store must not have targetAction's binding written
        let storeBindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(storeBindings[targetAction.rawValue] == nil)
        // Conflict rejection must be recorded
        #expect(model.conflictRejections[targetAction.rawValue] == conflictAction)
    }

    @Test func numberedActionRejectsNonDigit() async throws {
        // WHY: numbered actions stand in for the 1…9 family; binding a non-digit
        // produces a binding the app parser rejects — model must reject it, no disk write.
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.selectSurfaceByNumber // usesNumberedDigitMatching = true

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

        let nonDigitStroke = ShortcutStroke(key: "z", command: false, shift: false, option: false, control: true)
        await model.assign(stroke: nonDigitStroke, to: action)

        let storeBindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(storeBindings[action.rawValue] == nil)
        #expect(model.numberedDigitRejections.contains(action.rawValue))
    }

    @Test func clearThenRestoreRoundTrips() async throws {
        // WHY: clearOrRestore must snapshot the effective binding before clearing;
        // a second call on the same now-unbound action must restore exactly that snapshot.
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.openSettings
        let originalShortcut = StoredShortcut(first: ShortcutStroke(
            key: ",", command: true, shift: false, option: false, control: false
        ))

        try await store.set([action.rawValue: originalShortcut], for: catalog.shortcuts.bindings)

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await spin(until: { model.bindings[action.rawValue] != nil })

        // First clearOrRestore: effective is non-unbound → should cache + clear
        model.clearOrRestore(for: action)
        await spin(until: { model.bindings[action.rawValue] == StoredShortcut.unbound })

        #expect(model.restoreShortcuts[action.rawValue] == originalShortcut)

        // Second clearOrRestore: effective is unbound and restore cached → should restore
        model.clearOrRestore(for: action)
        await spin(until: { model.bindings[action.rawValue] == originalShortcut })

        let finalBindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(finalBindings[action.rawValue] == originalShortcut)
    }

    @Test func resetAllWritesEmpty() async throws {
        // WHY: resetAll must write an empty bindings dict and clear all in-memory
        // rejection/restore state — equivalent to pressing "Reset Defaults".
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.openSettings
        let someShortcut = StoredShortcut(first: ShortcutStroke(
            key: "p", command: true, shift: false, option: false, control: false
        ))

        try await store.set([action.rawValue: someShortcut], for: catalog.shortcuts.bindings)

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await spin(until: { model.bindings[action.rawValue] != nil })

        await model.resetAll()

        let storeBindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(storeBindings == [:])
        #expect(model.bareKeyRejections.isEmpty)
        #expect(model.numberedDigitRejections.isEmpty)
        #expect(model.conflictRejections.isEmpty)
        #expect(model.restoreShortcuts.isEmpty)
    }

    @Test func externalChangePrunesStaleConflictRejection() async throws {
        // WHY: a user editing cmux.json externally to remove a conflicting binding
        // must auto-dismiss the stale conflict banner — UI must not get permanently stuck.
        let (store, catalog, errorLog) = makeStore()
        let conflictAction = ShortcutAction.closeWindow
        let targetAction = ShortcutAction.openSettings
        let stroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false)

        try await store.set(
            [conflictAction.rawValue: StoredShortcut(first: stroke)],
            for: catalog.shortcuts.bindings
        )

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await spin(until: { model.bindings[conflictAction.rawValue] != nil })

        // Trigger conflict rejection
        await model.assign(stroke: stroke, to: targetAction)
        #expect(model.conflictRejections[targetAction.rawValue] != nil)

        // External edit: set conflicting action to unbound → removes the conflict
        try await store.set(
            [conflictAction.rawValue: StoredShortcut.unbound],
            for: catalog.shortcuts.bindings
        )
        await spin(until: { model.conflictRejections[targetAction.rawValue] == nil })

        #expect(model.conflictRejections[targetAction.rawValue] == nil)
    }

    @Test func markBareKeyRejectedInserts() {
        // WHY: markBareKeyRejected is the onBareKeyRejected callback path for
        // ShortcutListRowView; it must insert the action id into bareKeyRejections
        // so the row renders the bare-key error banner.
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.openSettings
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)

        model.markBareKeyRejected(action)

        #expect(model.bareKeyRejections.contains(action.rawValue))
    }

    @Test func assignChordWritesValidTwoStrokeChord() async throws {
        // WHY: assignChord is the recorder's onChord path for chord-capable
        // actions (wired from ShortcutListRowView). Only its rejection branches
        // were covered; the happy path — a non-conflicting, non-numbered chord —
        // must persist the chord verbatim to disk and leave no chord-mode or
        // rejection residue for the row. A first stroke using all four modifiers
        // collides with no default (defaults use at most three), so the write is
        // deterministically conflict-free regardless of default bindings.
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.openSettings // allowsChordShortcut, not numbered
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true),
            second: ShortcutStroke(key: "k", command: true, shift: false, option: false, control: false)
        )

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

        await model.assignChord(chord, to: action)
        await spin(until: { model.bindings[action.rawValue] == chord })

        // Persisted verbatim — openSettings is not numbered, so no digit normalization.
        let storeBindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(storeBindings[action.rawValue] == chord)
        // Happy path clears chord-mode arming and leaves no rejection state.
        #expect(!model.chordModeActions.contains(action.rawValue))
        #expect(!model.numberedDigitRejections.contains(action.rawValue))
        #expect(model.conflictRejections[action.rawValue] == nil)
    }

    @Test func whenOverrideIsParsedAndRetainedVerbatim() async throws {
        // WHY: the whenDriver branch of startObserving parses shortcuts.when
        // overrides used by conflict detection and keeps the raw expression
        // verbatim so the row can render the user's own clause text in its scope
        // caption. None of this observation path was covered before.
        let (store, catalog, errorLog) = makeStore()
        let action = ShortcutAction.openSettings

        // Pre-load a when override so the first stream delivery carries it.
        try await store.set([action.rawValue: "!sidebarFocus"], for: catalog.shortcuts.when)

        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await spin(until: { model.whenOverrideClauses[action.rawValue] != nil })

        // Parsed to the clause AST, and the raw expression retained verbatim.
        #expect(model.whenOverrideClauses[action.rawValue] == .not(.atom(.sidebarFocus)))
        #expect(model.whenOverrideRawStrings[action.rawValue] == "!sidebarFocus")

        // An external edit re-parses and re-captures the raw expression.
        try await store.set([action.rawValue: "sidebarFocus"], for: catalog.shortcuts.when)
        await spin(until: { model.whenOverrideClauses[action.rawValue] == .atom(.sidebarFocus) })

        #expect(model.whenOverrideRawStrings[action.rawValue] == "sidebarFocus")
    }
}
