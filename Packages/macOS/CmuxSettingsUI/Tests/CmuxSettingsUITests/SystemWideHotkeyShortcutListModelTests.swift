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

    /// Cmd+; is Mark Workspace as Done by default, so the host cannot register it system-wide.
    /// The user clears that in cmux, not in macOS, so the banner has to name the action.
    @Test func showHideKeystrokeHeldByAnotherActionNamesTheConflict() async {
        let fixture = makeFixture()
        let commandSemicolon = StoredShortcut(
            first: ShortcutStroke(key: ";", command: true)
        )
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog,
            canRegisterSystemWideHotkey: { _ in false }
        )

        await model.assign(stroke: commandSemicolon.first, to: .showHideAllWindows)

        let bindings = await fixture.store.value(
            for: fixture.catalog.shortcuts.bindings
        )
        #expect(bindings[ShortcutAction.showHideAllWindows.rawValue] == nil)
        #expect(
            model.validationMessage(for: .showHideAllWindows)
                == String.localizedStringWithFormat(
                    String(
                        localized: "shortcut.recorder.error.conflictsWithAction",
                        defaultValue: "This shortcut conflicts with %@ (%@)."
                    ),
                    ShortcutAction.markWorkspaceDone.displayName,
                    shortcutDisplayString(commandSemicolon, numbered: false)
                )
        )
    }

    /// Ctrl+N is Command Palette Next, which only fires while the palette is open and wins its
    /// context. A system-wide hotkey would take the key everywhere, so it is still a conflict.
    @Test func showHideKeystrokeHeldByAContextScopedActionNamesTheConflict() async {
        let fixture = makeFixture()
        let controlN = StoredShortcut(
            first: ShortcutStroke(key: "n", control: true)
        )
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog,
            canRegisterSystemWideHotkey: { _ in false }
        )

        await model.assign(stroke: controlN.first, to: .showHideAllWindows)
        // An unrelated store update re-checks pending conflicts; the banner has to survive it.
        model.pruneConflictRejections()

        #expect(
            model.validationMessage(for: .showHideAllWindows)
                == String.localizedStringWithFormat(
                    String(
                        localized: "shortcut.recorder.error.conflictsWithAction",
                        defaultValue: "This shortcut conflicts with %@ (%@)."
                    ),
                    ShortcutAction.commandPaletteNext.displayName,
                    shortcutDisplayString(controlN, numbered: false)
                )
        )
    }

    /// The banner goes away once the other action gives the keystroke up.
    @Test func showHideConflictBannerClearsWhenTheOtherActionIsUnbound() async {
        let fixture = makeFixture()
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog,
            canRegisterSystemWideHotkey: { _ in false }
        )
        model.startObserving()
        await spin(until: { model.hasLoadedBindings })

        await model.assign(
            stroke: ShortcutStroke(key: ";", command: true),
            to: .showHideAllWindows
        )
        #expect(model.validationMessage(for: .showHideAllWindows) != nil)

        // No direct prune: the binding update from the store has to clear it.
        await model.clearBinding(for: .markWorkspaceDone)
        await spin(until: { model.validationMessage(for: .showHideAllWindows) == nil })
    }

    /// The same rule from the other side: a context-scoped action cannot take the keystroke the
    /// system-wide hotkey holds, or the host would stop registering the hotkey without a word.
    @Test func contextScopedActionCannotTakeTheShowHideKeystroke() async throws {
        let fixture = makeFixture()
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog
        )
        let showHide = try #require(model.effective(for: .showHideAllWindows))

        await model.assign(stroke: showHide.first, to: .commandPaletteNext)

        let bindings = await fixture.store.value(
            for: fixture.catalog.shortcuts.bindings
        )
        #expect(bindings[ShortcutAction.commandPaletteNext.rawValue] == nil)
        #expect(
            model.validationMessage(for: .commandPaletteNext)
                == String.localizedStringWithFormat(
                    String(
                        localized: "shortcut.recorder.error.conflictsWithAction",
                        defaultValue: "This shortcut conflicts with %@ (%@)."
                    ),
                    ShortcutAction.showHideAllWindows.displayName,
                    shortcutDisplayString(showHide, numbered: false)
                )
        )
    }

    /// A keystroke no cmux action uses and the host still refuses keeps the system wording.
    @Test func showHideKeystrokeOnlyTheHostRefusesStaysReservedBySystem() async {
        let fixture = makeFixture()
        let model = ShortcutListModel(
            jsonStore: fixture.store,
            catalog: fixture.catalog,
            errorLog: fixture.errorLog,
            canRegisterSystemWideHotkey: { _ in false }
        )

        await model.assign(
            stroke: ShortcutStroke(
                key: "f20",
                command: true,
                shift: true,
                option: true,
                control: true,
                keyCode: 90
            ),
            to: .showHideAllWindows
        )

        let bindings = await fixture.store.value(
            for: fixture.catalog.shortcuts.bindings
        )
        #expect(bindings[ShortcutAction.showHideAllWindows.rawValue] == nil)
        #expect(
            model.validationMessage(for: .showHideAllWindows)
                == String(
                    localized: "shortcut.recorder.error.reservedBySystem",
                    defaultValue: "This keystroke is reserved by macOS."
                )
        )
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
