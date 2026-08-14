import AppKit
import CmuxSettings

/// Main-actor registry for checklist views that own a highlighted item.
///
/// A checklist action cannot be executed by ``AppDelegate`` alone because the
/// highlighted item is SwiftUI view state. Views register a short-lived bridge
/// while mounted; the prefix dispatcher resolves the action once and asks the
/// registry to hand it to the focused bridge. No process-wide singleton or
/// duplicate shortcut implementation is needed.
@MainActor
final class PrefixChordChecklistActionRegistry {
    @MainActor
    final class Bridge {
        var perform: @MainActor () -> Bool = { false }
        var isEligible: @MainActor () -> Bool = { false }
        var windowNumber: Int?

        func clear() {
            perform = { false }
            isEligible = { false }
            windowNumber = nil
        }
    }

    private var bridges: [ObjectIdentifier: Bridge] = [:]

    func register(_ bridge: Bridge) {
        bridges[ObjectIdentifier(bridge)] = bridge
    }

    func unregister(_ bridge: Bridge) {
        bridges.removeValue(forKey: ObjectIdentifier(bridge))
        bridge.clear()
    }

    func update(
        _ bridge: Bridge,
        windowNumber: Int?,
        isEligible: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor () -> Bool
    ) {
        bridge.windowNumber = windowNumber
        bridge.isEligible = isEligible
        bridge.perform = perform
        register(bridge)
    }

    @discardableResult
    func perform(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        guard action == .toggleChecklistItemComplete else { return false }
        let eventWindowNumber = event.window?.windowNumber
            ?? (event.windowNumber > 0 ? event.windowNumber : nil)
        guard let eventWindowNumber else { return false }

        // Iterate a snapshot so a view may unregister itself from its action
        // closure without invalidating this dispatch.
        let candidates = Array(bridges.values)
        for bridge in candidates {
            guard bridge.windowNumber == eventWindowNumber,
                bridge.isEligible() else {
                continue
            }
            if bridge.perform() {
                return true
            }
        }
        return false
    }
}
