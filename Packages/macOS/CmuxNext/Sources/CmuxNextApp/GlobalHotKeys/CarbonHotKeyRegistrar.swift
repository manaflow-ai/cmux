import Carbon.HIToolbox

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
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
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
            MainActor.assumeIsolated { CarbonHotKeyRegistrar.active?.onPress?(number) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
