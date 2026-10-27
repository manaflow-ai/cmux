import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing
import CmuxNextFocusUI

/// Message the Chief from Any App (`home.messageChiefFromAnyApp`): Message the Chief's system-wide
/// key, Ctrl-Opt-Cmd-C by default. GlobalHotKeyService registers it like Show/Hide All Windows and
/// Start Agent from Any App, only while the Chief pet is on (`home.chiefPetEnabled`, the binding's
/// `isEnabled`), and a press runs Message the Chief's handler through `ActionRegistry.perform`.
@MainActor @Suite(.serialized) struct MessageChiefGlobalHotKeyTests {
    static let action: ActionID = "home.messageChiefFromAnyApp"
    static let key = Shortcut("c", modifiers: [.control, .option, .command])

    /// Records registrations instead of calling Carbon.
    final class Recorder: GlobalHotKeyRegistrar {
        var onPress: ((UInt32) -> Void)?
        var registered: [UInt32: CarbonHotKey] = [:]
        func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool {
            registered[number] = hotKey
            return true
        }
        func unregister(number: UInt32) { registered[number] = nil }
    }

    @MainActor final class Summons { var count = 0 }

    static func settings(petOn: Bool) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-chief-hotkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(#"{"home": {"chiefPetEnabled": \#(petOn)}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, home)
    }

    @Test func theCatalogOffersItAsAGlobalKeyOnCtrlOptCmdC() throws {
        let registry = ActionRegistry.standard()
        let descriptor = try #require(registry.descriptor(for: Self.action))
        #expect(descriptor.title == "Message the Chief from Any App")
        #expect(descriptor.isGlobalHotKey)
        #expect(descriptor.defaultShortcut == Self.key)
        #expect(descriptor.surfaces.contains(.keyboard), "its own row in Settings > Keyboard Shortcuts")
        #expect(descriptor.isPersonOnly, "like Message the Chief: an agent cannot open the box over every app")
        #expect(registry.shortcutConflicts().isEmpty, "no other default binding takes Ctrl-Opt-Cmd-C")
        #expect(SystemReservedShortcuts.shared.table[Self.key] == nil)
        // The palette row stays Message the Chief, unbound: this action is its key.
        #expect(registry.descriptor(for: HomeChiefPetSetting.messageAction)?.defaultShortcut == nil)
    }

    @Test func aPressRunsMessageTheChiefWhileThePetIsOn() async throws {
        let (settings, home) = try await Self.settings(petOn: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = ActionRegistry.standard()
        let summons = Summons()
        HomeChiefPetSetting().bindMessage(into: registry, settings: { settings }, unavailable: "not ready") { _ in summons.count += 1 }
        #expect(registry.globalHotKeys()[Self.action] == Self.key)

        let recorder = Recorder()
        let service = GlobalHotKeyService(registry: registry, registrar: recorder, layout: { .ansi },
                                          showHideEnabled: { false }, startAgentEnabled: { false })
        service.start()
        defer { service.stop() }
        let hotKey = try #require(CarbonHotKey(Self.key, layout: .ansi))
        let number = try #require(recorder.registered.first(where: { $0.value == hotKey })?.key, "Ctrl-Opt-Cmd-C is registered")
        #expect(service.conflicts.isEmpty)
        recorder.onPress?(number)
        #expect(summons.count == 1, "the press ran Message the Chief's handler")
    }

    @Test func thePetOffLeavesTheKeyToOtherApps() async throws {
        let (settings, home) = try await Self.settings(petOn: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = ActionRegistry.standard()
        HomeChiefPetSetting().bindMessage(into: registry, settings: { settings }, unavailable: "not ready") { _ in }
        let recorder = Recorder()
        let service = GlobalHotKeyService(registry: registry, registrar: recorder, layout: { .ansi },
                                          showHideEnabled: { false }, startAgentEnabled: { false })
        service.apply()
        #expect(registry.globalHotKeys()[Self.action] == nil)
        #expect(recorder.registered.isEmpty)
        // Turning the pet on hands the service the key.
        try await settings.setSetting(at: HomeChiefPetSetting.configPath, to: .bool(true), by: SettingWriter(.user))
        service.apply()
        let hotKey = try #require(CarbonHotKey(Self.key, layout: .ansi))
        #expect(recorder.registered.values.contains(hotKey))
    }
}
