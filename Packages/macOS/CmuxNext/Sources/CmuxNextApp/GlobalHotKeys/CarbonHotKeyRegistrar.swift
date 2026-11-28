import Carbon.HIToolbox
import os

/// Faults from the Carbon event handler (a C callback, so no captured logger).
nonisolated enum CarbonHotKeyFaults {
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hotkeys")
}

/// `RegisterEventHotKey`-backed registrar. Carbon hot keys fire while
/// another app is frontmost and need no Accessibility or Input Monitoring
/// permission. The system delivers each press on the main thread through
/// one application event handler.
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistrar {
    var onPress: ((UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// 'cmux', so presses of other components' hot keys are left alone.
    nonisolated static let signature: OSType = 0x636D_7578
    /// The registrar receiving presses. The C callback cannot capture, and
    /// the app has one.
    private static weak var active: CarbonHotKeyRegistrar?

    func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool {
        installHandlerIfNeeded()
        unregister(number: number)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: number)
        // Exclusive, so a key another process holds is refused instead of
        // silently shared (two cmux builds would both answer one press).
        let options = OptionBits(kEventHotKeyExclusive)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), options, &ref)
        guard status == noErr, let ref else { return false }
        refs[number] = ref
        return true
    }

    func unregister(number: UInt32) {
        guard let ref = refs.removeValue(forKey: number) else { return }
        UnregisterEventHotKey(ref)
    }

    private func installHandlerIfNeeded() {
        Self.active = self
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == CarbonHotKeyRegistrar.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let number = hotKeyID.id
            // The application event target dispatches on the main thread; anywhere else, refuse the press.
            guard Thread.isMainThread else {
                CarbonHotKeyFaults.logger.fault("Carbon hot key event off the main thread; not handled")
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated { CarbonHotKeyRegistrar.active?.onPress?(number) } // main-proof: guarded by Thread.isMainThread above
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
