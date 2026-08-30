import Foundation
import Testing
import CmuxSettings
@testable import CmuxSettingsUI

/// Behavior tests for prefix and chord persistence in ``ShortcutListModel``.
@MainActor
@Suite struct PrefixChordShortcutListModelTests {

    private func makeStore() -> (JSONConfigStore, SettingCatalog, SettingsErrorLog, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-chord-list-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (
            JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json")),
            SettingCatalog(),
            SettingsErrorLog(),
            tempDir
        )
    }

    @Test func prefixIsDisabledByDefaultAndCanBePersisted() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()

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
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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

    @Test func changingPrefixRejectsCollidingPersistedChords() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let firstLeader = ShortcutStroke(key: "b", control: true)
        let secondLeader = ShortcutStroke(key: "g", control: true)
        let suffix = ShortcutStroke(key: "n")
        await model.assignChord(
            StoredShortcut(first: firstLeader, second: suffix),
            to: .newTab
        )
        await model.assignChord(
            StoredShortcut(first: secondLeader, second: suffix),
            to: .openSettings
        )

        await model.assignPrefix(ShortcutStroke(key: "x", control: true))

        #expect(model.prefix.isUnbound)
        #expect(model.prefixRejection == .chordConflict)
        let persistedPrefix = await store.value(for: catalog.shortcuts.prefix)
        #expect(persistedPrefix.isUnbound)
        let persisted = await store.value(for: catalog.shortcuts.bindings)
        #expect(
            persisted[ShortcutAction.newTab.rawValue]
                == StoredShortcut(first: firstLeader, second: suffix)
        )
        #expect(
            persisted[ShortcutAction.openSettings.rawValue]
                == StoredShortcut(first: secondLeader, second: suffix)
        )
    }

    @Test func overlappingPrefixWritesLeaveTheNewestValuePersisted() async throws {
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        model.startObserving()
        let initialPrefix = ShortcutStroke(key: "a", control: true)
        await model.assignPrefix(initialPrefix)
        await model.assignChord(
            StoredShortcut(
                first: initialPrefix,
                second: ShortcutStroke(key: "n")
            ),
            to: .newTab
        )

        async let first: Void = model.assignPrefix(ShortcutStroke(key: "b", control: true))
        async let second: Void = model.assignPrefix(ShortcutStroke(key: "c", control: true))
        _ = await (first, second)

        let persistedPrefix = await store.value(for: catalog.shortcuts.prefix)
        let persistedBindings = await store.value(for: catalog.shortcuts.bindings)
        let persistedChord = try #require(
            persistedBindings[ShortcutAction.newTab.rawValue]
        )
        #expect(persistedChord.first == persistedPrefix.first)
        #expect(persistedChord.second == ShortcutStroke(key: "n"))
        #expect(model.prefix.first == persistedPrefix.first)
    }

    @Test func malformedChordWithoutSuffixIsRejectedNotWritten() async throws {
        // A recorder teardown must not silently downgrade a requested chord to
        // a single-stroke binding at the persistence boundary.
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
        let (store, catalog, errorLog, tempDir) = makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
