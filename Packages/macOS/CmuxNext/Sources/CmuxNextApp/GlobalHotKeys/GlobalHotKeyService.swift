import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import Observation
import os

/// Registers every catalog action marked `isGlobalHotKey` as a system-wide
/// hot key with its effective shortcut, so it runs while another app is
/// frontmost. Follows rebinds (Settings, cmux.json) and keyboard layout
/// changes. A press runs the action through `ActionRegistry.perform`, the
/// same path as the palette, the menu and the CLI.
@Observable
final class GlobalHotKeyService {
    /// Actions whose shortcut the system refused, usually because another
    /// app holds the same key. Retried on the next change.
    private(set) var conflicts: Set<ActionID> = []
    @ObservationIgnored private let registry: ActionRegistry
    @ObservationIgnored private let registrar: any GlobalHotKeyRegistrar
    @ObservationIgnored private let layout: () -> KeyCodeLayout
    @ObservationIgnored private var registered: [ActionID: Registration] = [:]
    @ObservationIgnored private var nextNumber: UInt32 = 1
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hotkeys")

    struct Registration: Equatable {
        var hotKey: CarbonHotKey
        var number: UInt32
    }

    init(
        registry: ActionRegistry,
        registrar: any GlobalHotKeyRegistrar = CarbonHotKeyRegistrar(),
        layout: @escaping () -> KeyCodeLayout = KeyCodeLayout.current
    ) {
        self.registry = registry
        self.registrar = registrar
        self.layout = layout
    }

    /// Registers now, then follows shortcut and layout changes.
    func start() {
        guard tasks.isEmpty else { return }
        registrar.onPress = { [weak self] number in self?.press(number) }
        apply()
        let registry = registry
        tasks.append(Task { [weak self] in
            for await _ in Observations({ registry.globalHotKeys() }) {
                self?.apply()
            }
        })
        let layoutChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        tasks.append(Task { [weak self] in
            for await _ in DistributedNotificationCenter.default().notifications(named: layoutChanged) {
                self?.apply()
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        for registration in registered.values { registrar.unregister(number: registration.number) }
        registered.removeAll()
    }

    /// Brings the registered hot keys in line with the catalog.
    func apply() {
        let layout = layout()
        var wanted: [ActionID: CarbonHotKey] = [:]
        for (id, shortcut) in registry.globalHotKeys() {
            guard let hotKey = CarbonHotKey(shortcut, layout: layout) else {
                let name = id.rawValue
                let keys = shortcut.displayString
                logger.notice("global hot key \(name, privacy: .public): no key types \(keys, privacy: .public)")
                continue
            }
            wanted[id] = hotKey
        }
        for (id, registration) in registered where wanted[id] != registration.hotKey {
            registrar.unregister(number: registration.number)
            registered[id] = nil
        }
        var refused: Set<ActionID> = []
        for (id, hotKey) in wanted where registered[id] == nil {
            let number = nextNumber
            nextNumber += 1
            if registrar.register(hotKey, number: number) {
                registered[id] = Registration(hotKey: hotKey, number: number)
            } else {
                refused.insert(id)
                let name = id.rawValue
                logger.notice("global hot key \(name, privacy: .public) refused: another app holds it")
            }
        }
        if conflicts != refused { conflicts = refused }
    }

    private func press(_ number: UInt32) {
        guard let id = registered.first(where: { $0.value.number == number })?.key else { return }
        registry.perform(id)
    }
}
