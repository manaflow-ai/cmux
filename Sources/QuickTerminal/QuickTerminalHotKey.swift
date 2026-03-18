import AppKit
import Bonsplit
import Carbon

/// Registers a system-wide global hot key using the Carbon Event API.
/// This allows the Quick Terminal to be toggled even when cmux is not the active application.
@MainActor
final class QuickTerminalHotKey {
    /// Four-char signature identifying this app's hot keys ("CMUX").
    private static let hotKeySignature = OSType(0x434D5558)
    /// Unique ID for the Quick Terminal toggle hot key.
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Create a hot key handler that invokes the given action when the shortcut is pressed.
    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Register a system-wide hot key for the given shortcut. Returns `true` on success.
    @discardableResult
    func register(shortcut: StoredShortcut) -> Bool {
        unregister()

        guard let carbonKeyCode = carbonKeyCode(for: shortcut.key),
              !shortcut.key.isEmpty else {
#if DEBUG
            dlog("quickTerminal.hotKey.register failed: unsupported key=\"\(shortcut.key)\"")
#endif
            return false
        }

        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature,
                                     id: Self.hotKeyID)

        // Store self pointer for the C callback.
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }

            // Validate that the hot key event matches our registered signature and ID.
            guard hotKeyID.signature == QuickTerminalHotKey.hotKeySignature,
                  hotKeyID.id == QuickTerminalHotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }

            let this = Unmanaged<QuickTerminalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { @MainActor in
                this.action()
            }
            return noErr
        }

        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, pointer, &installedHandler
        )
        guard handlerStatus == noErr, let installedHandler else {
#if DEBUG
            dlog("quickTerminal.hotKey.register failed: InstallEventHandler status=\(handlerStatus)")
#endif
            return false
        }
        handlerRef = installedHandler

        var registeredKey: EventHotKeyRef?
        let keyStatus = RegisterEventHotKey(
            carbonKeyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &registeredKey
        )
        guard keyStatus == noErr, let registeredKey else {
#if DEBUG
            dlog("quickTerminal.hotKey.register failed: RegisterEventHotKey status=\(keyStatus)")
#endif
            RemoveEventHandler(installedHandler)
            handlerRef = nil
            return false
        }
        hotKeyRef = registeredKey
        return true
    }

    /// Unregister the current global hot key and event handler, if any.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    // MARK: - Key mapping

    /// Map a shortcut key string to a Carbon virtual key code.
    private func carbonKeyCode(for key: String) -> UInt32? {
        switch key.lowercased() {
        case "`": return UInt32(kVK_ANSI_Grave)
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        case "=": return UInt32(kVK_ANSI_Equal)
        case "-": return UInt32(kVK_ANSI_Minus)
        case "[": return UInt32(kVK_ANSI_LeftBracket)
        case "]": return UInt32(kVK_ANSI_RightBracket)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        case ";": return UInt32(kVK_ANSI_Semicolon)
        case "'": return UInt32(kVK_ANSI_Quote)
        case ",": return UInt32(kVK_ANSI_Comma)
        case ".": return UInt32(kVK_ANSI_Period)
        case "/": return UInt32(kVK_ANSI_Slash)
        case " ": return UInt32(kVK_Space)
        case "\r": return UInt32(kVK_Return)
        case "\t": return UInt32(kVK_Tab)
        default: return nil
        }
    }
}
