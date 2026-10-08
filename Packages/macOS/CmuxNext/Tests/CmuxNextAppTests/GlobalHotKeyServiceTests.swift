import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// Show/Hide All Windows, and every later action marked `isGlobalHotKey`,
/// registers a system-wide hot key that follows rebinds and runs the action
/// through the registry.
@MainActor
struct GlobalHotKeyServiceTests {
    final class FakeRegistrar: GlobalHotKeyRegistrar {
        var onPress: ((UInt32) -> Void)?
        var held: [UInt32: CarbonHotKey] = [:]
        var refused: Set<CarbonHotKey> = []
        var attempts = 0

        func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool {
            attempts += 1
            guard !refused.contains(hotKey) else { return false }
            held[number] = hotKey
            return true
        }

        func unregister(number: UInt32) {
            held[number] = nil
        }

        func press(_ hotKey: CarbonHotKey) {
            guard let number = held.first(where: { $0.value == hotKey })?.key else { return }
            onPress?(number)
        }
    }

    let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    func makeService(bound: Bool = true) -> (ActionRegistry, FakeRegistrar, GlobalHotKeyService, () -> Int) {
        let registry = ActionRegistry.standard()
        var runs = 0
        if bound { registry.bind("showHideAllWindows") { runs += 1 } }
        let registrar = FakeRegistrar()
        let service = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi }, showHideEnabled: { true })
        return (registry, registrar, service, { runs })
    }

    /// `app.globalHotKey` is off by default: Show/Hide All Windows takes no
    /// system-wide key until the user turns it on; turning it off releases it.
    @Test func showHideAllWindowsWaitsForAppGlobalHotKey() {
        let registry = ActionRegistry.standard()
        registry.bind("showHideAllWindows") {}
        let registrar = FakeRegistrar()
        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: controlOptionCommand)

        let byDefault = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi })
        byDefault.start()
        #expect(!registrar.held.values.contains(hotKey))
        byDefault.stop()

        var enabled = false
        let service = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi }, showHideEnabled: { enabled })
        service.start()
        defer { service.stop() }
        #expect(!registrar.held.values.contains(hotKey))
        enabled = true
        service.apply()
        #expect(registrar.held.values.contains(hotKey))
        enabled = false
        service.apply()
        #expect(!registrar.held.values.contains(hotKey))
    }

    @Test func showHideAllWindowsRegistersItsDefaultSystemWide() {
        let (_, registrar, service, runs) = makeService()
        service.start()
        defer { service.stop() }

        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: controlOptionCommand)
        #expect(Array(registrar.held.values) == [hotKey])
        registrar.press(hotKey)
        #expect(runs() == 1)
    }

    @Test func aRebindMovesTheHotKey() {
        let (registry, registrar, service, runs) = makeService()
        service.start()
        defer { service.stop() }

        registry.setShortcutOverride(Shortcut("h", modifiers: [.control, .option]), for: "showHideAllWindows")
        service.apply()
        let moved = CarbonHotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey))
        #expect(Array(registrar.held.values) == [moved])
        registrar.press(moved)
        #expect(runs() == 1)

        registry.setShortcutOverride(nil, for: "showHideAllWindows")
        service.apply()
        #expect(registrar.held.isEmpty)

        registry.removeShortcutOverride(for: "showHideAllWindows")
        service.apply()
        #expect(Array(registrar.held.values) == [CarbonHotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: controlOptionCommand)])
    }

    @Test func aKeyAnotherAppHoldsIsReportedAndRetried() {
        let (_, registrar, service, _) = makeService()
        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: controlOptionCommand)
        registrar.refused = [hotKey]
        service.start()
        defer { service.stop() }
        #expect(service.conflicts == ["showHideAllWindows"])
        #expect(registrar.held.isEmpty)

        registrar.refused = []
        service.apply()
        #expect(service.conflicts.isEmpty)
        #expect(Array(registrar.held.values) == [hotKey])
    }

    @Test func twoGlobalActionsOnOneKeyRegisterOnlyTheFirst() {
        func global(_ id: ActionID) -> ActionDescriptor {
            var descriptor = ActionDescriptor(id: id, title: id.rawValue, defaultShortcut: Shortcut("k", modifiers: [.control, .option]), category: .window)
            descriptor.isGlobalHotKey = true
            return descriptor
        }
        let registry = ActionRegistry(catalog: [global("first"), global("second")])
        registry.bind("first") {}
        registry.bind("second") {}
        let registrar = FakeRegistrar()
        let service = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi })
        service.start()
        defer { service.stop() }

        #expect(Array(registrar.held.values) == [CarbonHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))])
        #expect(service.conflicts == ["second"])
    }

    @Test func quickAgentChatRegistersControlOptionCommandSpace() {
        let registry = ActionRegistry.standard()
        var runs = 0
        registry.bind("palette.quickAgentChat") { runs += 1 }
        let registrar = FakeRegistrar()
        let service = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi })
        service.start()
        defer { service.stop() }

        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_Space), modifiers: controlOptionCommand)
        #expect(Array(registrar.held.values) == [hotKey])
        registrar.press(hotKey)
        #expect(runs == 1)
    }

    @Test func aKeyRefusedToTheFirstActionIsStillTriedForALaterOne() {
        func global(_ id: ActionID) -> ActionDescriptor {
            var descriptor = ActionDescriptor(id: id, title: id.rawValue, defaultShortcut: Shortcut("k", modifiers: [.control, .option]), category: .window)
            descriptor.isGlobalHotKey = true
            return descriptor
        }
        let registry = ActionRegistry(catalog: [global("first"), global("second")])
        registry.bind("first") {}
        registry.bind("second") {}
        let registrar = FakeRegistrar()
        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        registrar.refused = [hotKey]
        let service = GlobalHotKeyService(registry: registry, registrar: registrar, layout: { KeyCodeLayout.ansi })
        service.start()
        defer { service.stop() }
        // Another app holds the key: the refusal is not mistaken for the first action holding it.
        #expect(registrar.attempts == 2)
        #expect(service.conflicts == ["first", "second"])

        registrar.refused = []
        service.apply()
        #expect(Array(registrar.held.values) == [hotKey])
        #expect(service.conflicts == ["second"])
    }

    @Test func anOpenShortcutRecorderReleasesEveryHotKeyUntilItCloses() {
        let (registry, registrar, service, _) = makeService()
        let hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: controlOptionCommand)
        registrar.refused = [hotKey]
        service.start()
        defer { service.stop() }
        #expect(service.conflicts == ["showHideAllWindows"])

        registry.context.insert(.recordingShortcut)
        service.apply()
        #expect(registrar.held.isEmpty)
        // The Settings warning stays while the recorder is open.
        #expect(service.conflicts == ["showHideAllWindows"])

        registrar.refused = []
        registry.context.remove(.recordingShortcut)
        service.apply()
        #expect(Array(registrar.held.values) == [hotKey])
        #expect(service.conflicts.isEmpty)
    }

    @Test func anUnboundActionRegistersNothing() {
        let (_, registrar, service, _) = makeService(bound: false)
        service.start()
        defer { service.stop() }
        #expect(registrar.held.isEmpty)
    }

    @Test func stopReleasesEveryHotKey() {
        let (_, registrar, service, _) = makeService()
        service.start()
        service.stop()
        #expect(registrar.held.isEmpty)
    }

    @Test func layoutIndependentKeysUseTheirFixedCodes() {
        let layout = KeyCodeLayout.ansi
        #expect(layout.keyCode(for: Shortcut.spaceKey) == UInt32(kVK_Space))
        #expect(layout.keyCode(for: Shortcut.upArrowKey) == UInt32(kVK_UpArrow))
        #expect(layout.keyCode(for: Shortcut.returnKey) == UInt32(kVK_Return))
        let f5 = String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!))
        #expect(layout.keyCode(for: f5) == UInt32(kVK_F5))
        #expect(layout.keyCode(for: "Q") == UInt32(kVK_ANSI_Q))
        #expect(layout.keyCode(for: "é") == nil)
        #expect(KeyCodeLayout.keypad.contains(kVK_ANSI_KeypadDecimal))
        #expect(!KeyCodeLayout.keypad.contains(kVK_ANSI_Period))
    }
}
