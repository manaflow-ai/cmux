import AppKit
import CmuxNextActions
import CmuxNextSettings
import Observation
import os

/// Registers every catalog action marked `isGlobalHotKey` as a system-wide
/// hot key with its effective shortcut, so it runs while another app is
/// frontmost. Follows rebinds (Settings, cmux.json) and keyboard layout
/// changes. A press runs the action through `ActionRegistry.perform`, the
/// same path as the palette, the menu and the CLI.
///
/// Show/Hide All Windows registers only while `app.globalHotKey` is on
/// (off by default, coordinator decision 2026-10-06: a system-wide key is
/// taken from every other app only when the user asks for it); turning the
/// setting off releases it.
@Observable
final class GlobalHotKeyService {
    /// Actions whose key is not registered: another app holds it, or
    /// another global action already holds or (listed earlier) takes the
    /// same key. Retried on the next change; Settings marks their rows.
    private(set) var conflicts: Set<ActionID> = []
    @ObservationIgnored private let registry: ActionRegistry
    @ObservationIgnored private let registrar: any GlobalHotKeyRegistrar
    @ObservationIgnored private let layout: @MainActor () -> KeyCodeLayout
    /// `app.globalHotKey`, read on every apply (observed, so a change applies).
    @ObservationIgnored private let showHideEnabled: @MainActor () -> Bool
    @ObservationIgnored private var registered: [ActionID: Registration] = [:]
    @ObservationIgnored private var nextNumber: UInt32 = 1
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var layoutObserver: KeyboardLayoutObserver?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hotkeys")

    struct Registration: Equatable {
        var hotKey: CarbonHotKey
        var number: UInt32
    }

    init(
        registry: ActionRegistry,
        registrar: any GlobalHotKeyRegistrar = CarbonHotKeyRegistrar(),
        layout: @escaping @MainActor () -> KeyCodeLayout = KeyCodeLayout.current,
        showHideEnabled: @escaping @MainActor () -> Bool = { CmuxConfigSnapshot.globalHotKeyFallback }
    ) {
        self.registry = registry
        self.registrar = registrar
        self.layout = layout
        self.showHideEnabled = showHideEnabled
    }

    /// The action `app.globalHotKey` gates.
    static let gatedAction: ActionID = "showHideAllWindows"

    /// The global hot keys that may register now: the catalog's, without
    /// Show/Hide All Windows while `app.globalHotKey` is off.
    private func allowedHotKeys() -> [ActionID: Shortcut] {
        var keys = registry.globalHotKeys()
        if !showHideEnabled() { keys[Self.gatedAction] = nil }
        return keys
    }

    /// Registers now, then follows shortcut and layout changes.
    func start() {
        guard tasks.isEmpty else { return }
        registrar.onPress = { [weak self] number in self?.press(number) }
        apply()
        let registry = registry
        let showHideEnabled = showHideEnabled
        tasks.append(Task { [weak self] in
            // Suspension reads the whole focus context, so skip the changes
            // that move neither the keys nor the suspension.
            var last: (keys: [ActionID: Shortcut], suspended: Bool, enabled: Bool)?
            for await next in Observations({
                (keys: registry.globalHotKeys(), suspended: registry.globalHotKeysSuspended, enabled: showHideEnabled())
            }) {
                if let last, last == next { continue }
                last = next
                self?.apply()
            }
        })
        layoutObserver = KeyboardLayoutObserver { [weak self] in self?.apply() }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        layoutObserver = nil
        for registration in registered.values { registrar.unregister(number: registration.number) }
        registered.removeAll()
    }

    /// Brings the registered hot keys in line with the catalog. While a
    /// shortcut recorder is open every key is released and `conflicts`
    /// keeps its last value; closing it registers them again.
    func apply() {
        if registry.globalHotKeysSuspended {
            for registration in registered.values { registrar.unregister(number: registration.number) }
            registered.removeAll()
            return
        }
        let layout = layout()
        var wanted: [ActionID: CarbonHotKey] = [:]
        for (id, shortcut) in allowedHotKeys() {
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
        // Two shortcuts can land on one physical key (a character the layout
        // lacks falls back to its ANSI key). An action already holding the
        // key keeps it; among new registrations, catalog order decides.
        var taken = Set(registered.values.map(\.hotKey))
        let order = Dictionary(registry.descriptors.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in wanted.keys.sorted(by: { order[$0, default: .max] < order[$1, default: .max] }) where registered[id] == nil {
            guard let hotKey = wanted[id] else { continue }
            guard !taken.contains(hotKey) else {
                refused.insert(id)
                let name = id.rawValue
                logger.notice("global hot key \(name, privacy: .public) refused: another global action uses the same key")
                continue
            }
            let number = nextNumber
            nextNumber += 1
            if registrar.register(hotKey, number: number) {
                registered[id] = Registration(hotKey: hotKey, number: number)
                taken.insert(hotKey)
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
