import AppKit
import Carbon.HIToolbox

/// Registers a process-global hotkey to toggle `MenubarSearchPopover`.
///
/// Default chord: ⌥⌘F (kVK_ANSI_F + cmd+option). User-rebindable in
/// Settings (TODO: surface in `BetaFeaturesSettingsView` until promoted).
@MainActor
public final class GlobalSearchHotkey {
    public static let shared = GlobalSearchHotkey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    public func install(keyCode: UInt32 = UInt32(kVK_ANSI_F),
                        modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        uninstall()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MenubarSearchPopover.shared.toggle() }
            return noErr
        }, 1, &spec, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x434D5853 /* CMXS */),
                                 id: 1)
        RegisterEventHotKey(keyCode, modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    public func uninstall() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
