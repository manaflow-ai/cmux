import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite struct SystemWideHotkeyShortcutListModelTests {
    @Test func nonRegistrableShowHideBindingDoesNotReserveGlobalSearch() async throws {
        let fixture = makeFixture()
        let commandPeriod = StoredShortcut(
            first: ShortcutStroke(key: ".", command: true)
        )
        try await fixture.store.set(
            [
                ShortcutAction.showHideAllWindows.rawValue: commandPeriod,
                ShortcutAction.globalSearch.rawValue: commandPeriod,
            ],
            for: fixture.catalog.shortcuts.bindings
        )
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog
        )
        model.startObserving()
        await spin(until: { model.bindings.count == 2 })

        #expect(model.effective(for: .showHideAllWindows) == nil)
        #expect(model.effective(for: .globalSearch) == commandPeriod)
    }

    @Test func shiftOnlyShowHideBindingUsesSystemWideModifierRejection() async {
        let fixture = makeFixture()
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog
        )

        await model.assign(
            stroke: ShortcutStroke(key: "f", shift: true),
            to: .showHideAllWindows
        )

        let bindings = await fixture.store.value(
            for: fixture.catalog.shortcuts.bindings
        )
        #expect(bindings[ShortcutAction.showHideAllWindows.rawValue] == nil)
        #expect(
            model.validationMessage(for: .showHideAllWindows)
                == String(
                    localized: "shortcut.recorder.error.systemWideHotkeyRequiresModifier",
                    defaultValue: "System-wide hotkeys must include Command, Option, or Control."
                )
        )
    }

    @Test func hostRegistrationPolicyControlsGlobalSearchReservation() async throws {
        let fixture = makeFixture()
        let rejectedByHost = StoredShortcut(
            first: ShortcutStroke(
                key: "f20",
                command: true,
                shift: true,
                option: true,
                control: true,
                keyCode: 90
            )
        )
        try await fixture.store.set(
            [
                ShortcutAction.showHideAllWindows.rawValue: rejectedByHost,
                ShortcutAction.globalSearch.rawValue: rejectedByHost,
            ],
            for: fixture.catalog.shortcuts.bindings
        )
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog,
            canRegisterSystemWideHotkey: { $0 != rejectedByHost }
        )
        model.startObserving()
        await spin(until: { model.bindings.count == 2 })

        #expect(model.effective(for: .showHideAllWindows) == nil)
        #expect(model.effective(for: .globalSearch) == rejectedByHost)
    }

    private func makeFixture() -> (
        store: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "system-wide-hotkey-shortcut-list-model-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json")),
            SettingCatalog(),
            SettingsErrorLog()
        )
    }

    private func spin(until condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }
}
