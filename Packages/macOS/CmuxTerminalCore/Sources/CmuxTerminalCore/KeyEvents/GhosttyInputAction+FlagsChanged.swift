import AppKit
public import GhosttyKit
import Carbon.HIToolbox

extension ghostty_input_action_e {
    /// Resolves whether a `flagsChanged` event is a modifier press or release.
    ///
    /// `flagsChanged` is used for both modifier presses and releases on macOS.
    /// Returning the wrong edge leaves Ghostty with a phantom held modifier
    /// until a later focus loss flushes release events into the PTY. The
    /// device-side masks distinguish left/right siblings of the same modifier
    /// so releasing one side while the other stays held reports a release for
    /// the released key.
    ///
    /// A static factory on the action type itself: the translation is a pure
    /// function of the event payload, so the surface view, IME path, and
    /// tests share this one source of truth.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code from the `flagsChanged` event.
    ///   - modifierFlagsRawValue: The raw `NSEvent.ModifierFlags` value,
    ///     including device-dependent side bits.
    /// - Returns: The press/release action for the modifier key, or `nil` when
    ///   the key code is not a modifier.
    public static func modifierActionForFlagsChanged(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt
    ) -> ghostty_input_action_e? {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        let modifierActive: Bool
        switch keyCode {
        case 0x39:
            modifierActive = flags.contains(.capsLock)
        case 0x38, 0x3C:
            modifierActive = flags.contains(.shift)
        case 0x3B, 0x3E:
            modifierActive = flags.contains(.control)
        case 0x3A, 0x3D:
            modifierActive = flags.contains(.option)
        case 0x37, 0x36:
            modifierActive = flags.contains(.command)
        default:
            return nil
        }

        guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

        let sidePressed: Bool
        switch keyCode {
        case 0x38:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
        case 0x3C:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3B:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
        case 0x3E:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3A:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        case 0x3D:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x37:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
        case 0x36:
            sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            sidePressed = true
        }

        return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }
}
