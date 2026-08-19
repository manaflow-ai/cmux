import Foundation
import Testing
import CmuxSettings
@testable import CmuxSettingsUI

/// Behavior tests for prefix and chord persistence in ``ShortcutListModel``.
@MainActor
@Suite struct PrefixChordShortcutListModelTests {

    private func makeStore() -> (JSONConfigStore, SettingCatalog, SettingsErrorLog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-chord-list-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (
            JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json")),
            SettingCatalog(),
            SettingsErrorLog()
        )
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    @Test func prefixIsDisabledByDefaultAndCanBePersisted() async throws {
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

        await spin(until: { model.prefix.isUnbound })
        #expect(model.prefix == .unbound)

        let leader = ShortcutStroke(key: "b", control: true)
        await model.assignPrefix(leader)
        #expect(await store.value(for: catalog.shortcuts.prefix) == StoredShortcut(first: leader))
        #expect(model.prefix == StoredShortcut(first: leader))

        await model.clearPrefix()
        #expect(await store.value(for: catalog.shortcuts.prefix) == .unbound)
        #expect(model.prefix.isUnbound)
    }

    @Test func chordAssignmentUsesConfiguredPrefix() async throws {
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "b", control: true))

        let recorded = StoredShortcut(
            first: ShortcutStroke(key: "x", command: true),
            second: ShortcutStroke(key: "n")
        )
        await model.assignChord(recorded, to: .newTab)

        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(
            persisted[ShortcutAction.newTab.rawValue] == StoredShortcut(
                first: ShortcutStroke(key: "b", control: true),
                second: ShortcutStroke(key: "n")
            )
        )
        #expect(model.chordModeActions.isEmpty)
    }

    @Test func changingPrefixRebasesPersistedChords() async throws {
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let firstPrefix = ShortcutStroke(key: "b", control: true)
        let secondPrefix = ShortcutStroke(key: "c", control: true)
        await model.assignPrefix(firstPrefix)
        await model.assignChord(
            StoredShortcut(
                first: firstPrefix,
                second: ShortcutStroke(key: "n")
            ),
            to: .newTab
        )

        await model.assignPrefix(secondPrefix)

        #expect(
            await store.value(for: catalog.shortcuts.bindings)[ShortcutAction.newTab.rawValue]
                == StoredShortcut(first: secondPrefix, second: ShortcutStroke(key: "n"))
        )
    }

    @Test func overlappingPrefixWritesLeaveTheNewestValuePersisted() async throws {
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        async let first: Void = model.assignPrefix(ShortcutStroke(key: "b", control: true))
        async let second: Void = model.assignPrefix(ShortcutStroke(key: "c", control: true))
        _ = await (first, second)

        #expect(
            await store.value(for: catalog.shortcuts.prefix)
                == StoredShortcut(first: ShortcutStroke(key: "c", control: true))
        )
        #expect(model.prefix == StoredShortcut(first: ShortcutStroke(key: "c", control: true)))
    }

    @Test func malformedChordWithoutSuffixIsRejectedNotWritten() async throws {
        // A recorder teardown must not silently downgrade a requested chord to
        // a single-stroke binding at the persistence boundary.
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "b", control: true))

        await model.assignChord(
            StoredShortcut(first: ShortcutStroke(key: "x", command: true)),
            to: .newTab
        )

        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(persisted[ShortcutAction.newTab.rawValue] == nil)
        #expect(!model.chordModeActions.contains(ShortcutAction.newTab.rawValue))
    }

    @Test func configuredSpacePrefixAllowsChordForModifierOnlyAction() async throws {
        // Space is a valid shared leader even though ordinary app actions reject
        // bare single-stroke bindings.
        let (store, catalog, errorLog) = makeStore()
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        await model.assignPrefix(ShortcutStroke(key: "space"))

        let suffix = ShortcutStroke(key: "n")
        await model.assignChord(
            StoredShortcut(
                first: ShortcutStroke(key: "ignored", command: true),
                second: suffix
            ),
            to: .newTab
        )

        let expected = StoredShortcut(first: ShortcutStroke(key: "space"), second: suffix)
        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(persisted[ShortcutAction.newTab.rawValue] == expected)
        #expect(ShortcutAction.newTab.shortcutBindingPolicyResult(for: expected) == .accepted)
        #expect(ShortcutAction.newTab.effectivePersistedShortcut(expected) == expected)
    }
}
