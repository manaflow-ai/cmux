import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct ShortcutListLegacyOverrideTests {
    private func makeDefaultsStore(
        legacyBindings: [ShortcutAction: StoredShortcut]
    ) throws -> (store: UserDefaultsSettingsStore, suiteName: String) {
        let suiteName = "shortcut-list-legacy-override-\(UUID().uuidString)"
        do {
            let setup = try #require(UserDefaults(suiteName: suiteName))
            setup.removePersistentDomain(forName: suiteName)
            for (action, shortcut) in legacyBindings {
                setup.set(
                    try legacyShortcutData(shortcut),
                    forKey: "shortcut.\(action.rawValue)"
                )
            }
        }
        return (
            UserDefaultsSettingsStore(
                defaults: UserDefaults(suiteName: suiteName)!
            ),
            suiteName
        )
    }

    private func legacyShortcutData(_ shortcut: StoredShortcut) throws -> Data {
        var payload: [String: Any] = [
            "key": shortcut.first.key,
            "command": shortcut.first.command,
            "shift": shortcut.first.shift,
            "option": shortcut.first.option,
            "control": shortcut.first.control,
            "chordCommand": shortcut.second?.command ?? false,
            "chordShift": shortcut.second?.shift ?? false,
            "chordOption": shortcut.second?.option ?? false,
            "chordControl": shortcut.second?.control ?? false,
        ]
        if let keyCode = shortcut.first.keyCode {
            payload["keyCode"] = keyCode
        }
        if let second = shortcut.second {
            payload["chordKey"] = second.key
            if let keyCode = second.keyCode {
                payload["chordKeyCode"] = keyCode
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func makeJSONStore() -> JSONConfigStore {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-legacy-override-\(UUID().uuidString).json")
        return JSONConfigStore(fileURL: configURL)
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    @Test func settingsDisplaysLegacyOverrideUsedByRuntime() throws {
        let legacyShortcut = StoredShortcut(first: ShortcutStroke(
            key: "]",
            command: true,
            shift: true,
            keyCode: 30
        ))
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [.nextSidebarTab: legacyShortcut]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let model = ShortcutListModel(
            jsonStore: makeJSONStore(),
            userDefaultsStore: defaultsStore,
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )

        #expect(ShortcutAction.nextSidebarTab.defaultShortcut != legacyShortcut)
        #expect(model.effective(for: .nextSidebarTab) == legacyShortcut)
    }

    @Test func jsonOverrideTakesPrecedenceOverLegacyOverride() async throws {
        let action = ShortcutAction.nextSidebarTab
        let legacyShortcut = StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true))
        let jsonShortcut = StoredShortcut(first: ShortcutStroke(key: "]", command: true, option: true))
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [action: legacyShortcut]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let jsonStore = makeJSONStore()
        let catalog = SettingCatalog()
        try await jsonStore.set([action.rawValue: jsonShortcut], for: catalog.shortcuts.bindings)
        let model = ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await spin(until: { model.bindings[action.rawValue] == jsonShortcut })

        #expect(model.effective(for: action) == jsonShortcut)
    }

    @Test func externalLegacyChangeRefreshesEffectiveBinding() async throws {
        let action = ShortcutAction.nextSidebarTab
        let original = StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true))
        let replacement = StoredShortcut(first: ShortcutStroke(key: "]", command: true, option: true))
        let (defaultsStore, suiteName) = try makeDefaultsStore(legacyBindings: [action: original])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = ShortcutListModel(
            jsonStore: makeJSONStore(),
            userDefaultsStore: defaultsStore,
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )
        model.startObserving()

        let externalDefaults = try #require(UserDefaults(suiteName: suiteName))
        externalDefaults.set(try legacyShortcutData(replacement), forKey: "shortcut.\(action.rawValue)")
        await spin(until: { model.effective(for: action) == replacement })

        #expect(model.effective(for: action) == replacement)
    }

    @Test func legacyOverrideParticipatesInConflictDetection() async throws {
        let conflictAction = ShortcutAction.closeWindow
        let targetAction = ShortcutAction.openSettings
        let shortcut = StoredShortcut(first: ShortcutStroke(
            key: "j",
            command: true,
            shift: true,
            option: true,
            control: true
        ))
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [conflictAction: shortcut]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let jsonStore = makeJSONStore()
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        await model.assign(stroke: shortcut.first, to: targetAction)

        #expect(model.conflictRejections[targetAction.rawValue] == conflictAction)
        #expect(await jsonStore.value(for: catalog.shortcuts.bindings)[targetAction.rawValue] == nil)
    }

    @Test func successfulEditRetiresSupersededLegacyOverride() async throws {
        let action = ShortcutAction.showHideAllWindows
        let legacyShortcut = StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true))
        let replacement = StoredShortcut(first: ShortcutStroke(
            key: "j",
            command: true,
            shift: true,
            option: true,
            control: true
        ))
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [action: legacyShortcut]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let jsonStore = makeJSONStore()
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        await model.assign(stroke: replacement.first, to: action)

        let verify = try #require(UserDefaults(suiteName: suiteName))
        #expect(verify.object(forKey: "shortcut.\(action.rawValue)") == nil)
        #expect(await jsonStore.value(for: catalog.shortcuts.bindings)[action.rawValue] == replacement)
        #expect(model.effective(for: action) == replacement)
    }

    @Test func failedEditPreservesLegacyOverride() async throws {
        let action = ShortcutAction.nextSidebarTab
        let legacyShortcut = StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true))
        let replacement = StoredShortcut(first: ShortcutStroke(
            key: "j",
            command: true,
            shift: true,
            option: true,
            control: true
        ))
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [action: legacyShortcut]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let blockedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-legacy-write-failure-\(UUID().uuidString)")
        try Data().write(to: blockedParent)
        let jsonStore = JSONConfigStore(fileURL: blockedParent.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        await model.assign(stroke: replacement.first, to: action)

        let verify = try #require(UserDefaults(suiteName: suiteName))
        #expect(verify.object(forKey: "shortcut.\(action.rawValue)") != nil)
        #expect(model.effective(for: action) == legacyShortcut)
    }

    @Test func resetDefaultsClearsEveryLegacyOverride() async throws {
        let nextAction = ShortcutAction.nextSidebarTab
        let previousAction = ShortcutAction.prevSidebarTab
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [
                nextAction: StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true)),
                previousAction: StoredShortcut(first: ShortcutStroke(key: "[", command: true, shift: true)),
            ]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let jsonStore = makeJSONStore()
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: jsonStore,
            userDefaultsStore: defaultsStore,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        await model.resetAll()

        let verify = try #require(UserDefaults(suiteName: suiteName))
        #expect(verify.object(forKey: "shortcut.\(nextAction.rawValue)") == nil)
        #expect(verify.object(forKey: "shortcut.\(previousAction.rawValue)") == nil)
        #expect(model.effective(for: nextAction) == nextAction.defaultShortcut)
        #expect(model.effective(for: previousAction) == previousAction.defaultShortcut)
    }

    @Test func resetNotifiesHostAfterLegacyCleanup() async throws {
        let action = ShortcutAction.nextSidebarTab
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [
                action: StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true)),
            ]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        var legacyWasPresentWhenNotified: Bool?
        let model = ShortcutListModel(
            jsonStore: makeJSONStore(),
            userDefaultsStore: defaultsStore,
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog(),
            onShortcutsChanged: {
                legacyWasPresentWhenNotified = UserDefaults(suiteName: suiteName)?
                    .object(forKey: "shortcut.\(action.rawValue)") != nil
            }
        )

        await model.resetAll()

        #expect(legacyWasPresentWhenNotified == false)
    }

    @Test func resetAllSettingsClearsLegacyShortcutOverrides() async throws {
        let action = ShortcutAction.nextSidebarTab
        let (defaultsStore, suiteName) = try makeDefaultsStore(
            legacyBindings: [
                action: StoredShortcut(first: ShortcutStroke(key: "]", command: true, shift: true)),
            ]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let jsonStore = makeJSONStore()
        let catalog = SettingCatalog()
        let section = ResetSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            hostActions: NoopSettingsHostActions()
        )

        await section.resetAll()

        let verify = try #require(UserDefaults(suiteName: suiteName))
        #expect(verify.object(forKey: "shortcut.\(action.rawValue)") == nil)
        #expect(await jsonStore.value(for: catalog.shortcuts.bindings).isEmpty)
    }
}
