import CmuxNextWakeups
import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep for Auto chat placement (``AcpmuxChatPlaceMover``): `IORegisterForSystemPower` on the
/// main run loop, so nothing polls. Closing the lid, idle sleep and Apple menu > Sleep all arrive as
/// `kIOMessageSystemWillSleep`: `willSleep` runs (bounded by its caller, at most
/// ``AcpmuxChatPlaceMover/sleepHold``) and only then is the sleep allowed (`IOAllowPowerChange`);
/// macOS sleeps anyway 30 s after it asked. `kIOMessageCanSystemSleep` (idle sleep asking first) is
/// always allowed: Auto never keeps the Mac awake, it only finishes moving. Wake says `didWake`.
@MainActor
final class ChatPlaceSleepGate {
    // The IOKit message ids (`iokit_common_msg(0x270 | 0x280 | 0x300)`; the C macros do not import).
    nonisolated static let canSystemSleep: UInt32 = 0xE000_0270
    nonisolated static let systemWillSleep: UInt32 = 0xE000_0280
    nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let willSleep: @MainActor () async -> Void
    private let didWake: @MainActor () -> Void
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(willSleep: @escaping @MainActor () async -> Void, didWake: @escaping @MainActor () -> Void) {
        (self.willSleep, self.didWake) = (willSleep, didWake)
    }

    /// Registers once; false when IOKit refused.
    func start() -> Bool {
        guard root == 0 else { return true }
        // The gate lives as long as its mover, the app's lifetime (``stop()`` before it goes), so the
        // unretained context never dangles.
        let context = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(context, &port, { context, _, type, argument in
            guard let context else { return }
            let gate = Unmanaged<ChatPlaceSleepGate>.fromOpaque(context).takeUnretainedValue()
            let id = Int(bitPattern: argument)
            MainDelivery().run { gate.message(type, id) }
        }, &notifier)
        guard root != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        guard root != 0 else { return }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(root)
        if let port { IONotificationPortDestroy(port) }
        (root, port, notifier) = (0, nil, 0)
    }

    /// What the gate does with one system power message.
    enum Decision: Equatable, Sendable {
        /// Idle sleep asks first: always allowed, Auto never keeps the Mac awake.
        case allow
        /// The Mac will sleep: run `willSleep` (bounded), then allow it.
        case holdThenAllow
        /// The Mac woke: say `didWake`.
        case wake
        /// Any other message.
        case ignore
    }

    nonisolated static func decision(for type: UInt32) -> Decision {
        switch type {
        case canSystemSleep: .allow
        case systemWillSleep: .holdThenAllow
        case systemHasPoweredOn: .wake
        default: .ignore
        }
    }

    private func message(_ type: UInt32, _ id: Int) {
        let root = root
        switch Self.decision(for: type) {
        case .allow:
            IOAllowPowerChange(root, id)
        case .holdThenAllow:
            // task-owner: the sleep hold: willSleep is bounded (sleepHold), then the sleep goes on.
            Task { [willSleep] in
                await willSleep()
                IOAllowPowerChange(root, id)
            }
        case .wake:
            didWake()
        case .ignore:
            break
        }
    }
}
