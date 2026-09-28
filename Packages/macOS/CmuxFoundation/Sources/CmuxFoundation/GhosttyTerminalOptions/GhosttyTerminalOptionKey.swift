/// A Ghostty config key that Settings > Terminal edits with a native control.
///
/// The raw value is the exact Ghostty config key, which the row also shows as
/// its caption so people can find the same option in their config files.
public enum GhosttyTerminalOptionKey: String, CaseIterable, Sendable {
    case fontFamily = "font-family"
    case fontSize = "font-size"
    case cursorStyle = "cursor-style"
    case cursorStyleBlink = "cursor-style-blink"
    case windowPaddingX = "window-padding-x"
    case windowPaddingY = "window-padding-y"
    case backgroundOpacity = "background-opacity"
    case backgroundBlur = "background-blur"
    case macosOptionAsAlt = "macos-option-as-alt"
    case scrollbackLimit = "scrollback-limit"
}
