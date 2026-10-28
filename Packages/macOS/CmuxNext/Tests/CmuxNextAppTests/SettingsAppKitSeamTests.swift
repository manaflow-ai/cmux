import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextWakeups
import Foundation
import Testing

/// CmuxNextSettings imports no AppKit (p15-oracle-133): its function-key characters and its modifier
/// conversion stand in for AppKit's, it follows activation through `AppEvents.subscribeToActivation`,
/// and its refused-value toast goes through CmuxNextSettingsWindow's presenter. These pin each stand-in
/// to the AppKit value it replaces.
@MainActor @Suite struct SettingsAppKitSeamTests {
    private static func character(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code)) ?? " ")) }

    @Test func configKeyTokensParseToAppKitsFunctionKeyCharacters() throws {
        let keys: [(String, Int)] = [
            ("left", NSLeftArrowFunctionKey), ("right", NSRightArrowFunctionKey), ("up", NSUpArrowFunctionKey),
            ("down", NSDownArrowFunctionKey), ("home", NSHomeFunctionKey), ("end", NSEndFunctionKey),
            ("pageup", NSPageUpFunctionKey), ("pagedown", NSPageDownFunctionKey),
        ] + (1...20).map { number -> (String, Int) in ("f\(number)", NSF1FunctionKey + number - 1) }
        for (token, code) in keys {
            let stroke = try #require(ShortcutBindingFormat.parseStroke("cmd+\(token)"), "\(token) did not parse")
            #expect(stroke.key == Self.character(code), "\(token) is not AppKit's function-key character")
            #expect(ShortcutBindingFormat.configString(stroke) == "cmd+\(token)", "\(token) does not write back")
        }
    }

    @Test func strokesConvertToTheAppKitModifierFlags() {
        let stroke = ShortcutStrokeSpec(key: "p", command: true, shift: true, option: false, control: true)
        let shortcut = SettingsApplier.shortcut(for: stroke)
        #expect(shortcut == Shortcut("p", modifiers: [.command, .shift, .control]))
        #expect(SettingsApplier.stroke(for: Shortcut("k", modifiers: [.option, .shift])) == ShortcutStrokeSpec(key: "k", shift: true, option: true))
        for flags: NSEvent.ModifierFlags in [[], [.command], [.shift], [.option], [.control], [.command, .shift, .option, .control]] {
            let original = Shortcut("x", modifiers: flags)
            #expect(SettingsApplier.shortcut(for: SettingsApplier.stroke(for: original)) == original)
        }
    }

    @Test func managedSettingsFollowAppKitsActivationNotice() throws {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: directory.appendingPathComponent("cmux-next.json"),
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        settings.followActivation(on: events)
        #expect(events.subscriberCount(NSApplication.didBecomeActiveNotification) == 1)
    }

    @Test func thePresenterFollowsKeyWindowsAndShowsNothingWithoutAWindow() {
        let center = NotificationCenter()
        let presenter = SettingsDiagnosticToastPresenter(events: AppEvents(center: center), toasts: CmuxToastCenter())
        var becameKey = 0
        presenter.followKeyWindows { becameKey += 1 }
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        let end = Date(timeIntervalSinceNow: 2)
        while becameKey == 0, Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(becameKey == 1, "a window becoming key did not retry the pending notice")
        if NSApp?.keyWindow == nil, NSApp?.mainWindow == nil {
            let notice = SettingsDiagnosticToast(id: "settings-diagnostics", message: "m", actionTitle: "Open File", duration: nil)
            #expect(presenter.show(notice, onAction: {}) == nil)
        }
    }

    /// Settings names no CmuxToast (p15-oracle-134): its notice draws as the toast it built before, one
    /// button and its time-out, and a notice with no duration stays until closed.
    @Test func aNoticeDrawsAsTheToastSettingsBuiltBefore() {
        let timed = SettingsDiagnosticToast(id: "settings-diagnostics", message: "m", actionTitle: "Show in Settings", duration: .seconds(12))
        #expect(SettingsDiagnosticToastPresenter.toast(timed)
            == CmuxToast(id: "settings-diagnostics", message: "m", action: CmuxToast.Action(title: "Show in Settings"), duration: .seconds(12)))
        var kept = timed
        kept.duration = nil
        #expect(SettingsDiagnosticToastPresenter.toast(kept).duration == CmuxToast.untilClosed)
        #expect(SettingsDiagnosticToastPresenter.toast(kept).action?.isUndo == false)
    }

    @Test func theDiagnosticToastsTakeTheAppsOneKeyWindowObserverThroughThePresenter() throws {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        #expect(!events.isObserving(NSWindow.didBecomeKeyNotification))
        settings.start(announcingDiagnostics: SettingsDiagnosticToastPresenter(events: events, toasts: CmuxToastCenter()))
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 1)
        settings.stop()
    }
}
