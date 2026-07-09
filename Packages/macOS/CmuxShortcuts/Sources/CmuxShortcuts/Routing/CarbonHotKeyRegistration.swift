/// The Carbon descriptor identifying one registered system-wide hot key: the
/// virtual key code plus the OR-ed Carbon modifier mask the app hands to
/// `RegisterEventHotKey`.
///
/// ## Why this value exists
///
/// The app target registers each enabled global shortcut as a Carbon event hot
/// key and keeps a per-`Action` record of what it registered, so it can detect
/// when a shortcut's resolved key code or modifiers changed and re-register only
/// the differences. That record is exactly these two `UInt32` fields, and
/// nothing about it reaches window, tab, or focus state, so it cohereres as a
/// pure `Sendable`, `Equatable` value. The app's `ShortcutStroke` produces it
/// (resolved key code plus `carbonModifiers`) and the system-wide hotkey
/// controller stores and compares it.
///
/// ## Faithful relocation
///
/// Byte-faithful move of the app target's former `CarbonHotKeyRegistration`
/// struct (two `let UInt32` fields, `Equatable`). The memberwise initializer and
/// stored properties are now `public` so the app-side producers and the
/// controller's registration dictionary keep constructing and comparing it
/// unchanged; the implicit `Sendable` conformance is made explicit because the
/// value is a pure descriptor.
public struct CarbonHotKeyRegistration: Equatable, Sendable {
    /// The Carbon virtual key code passed to `RegisterEventHotKey`.
    public let keyCode: UInt32
    /// The OR-ed Carbon modifier mask (`cmdKey`/`shiftKey`/`optionKey`/`controlKey`).
    public let modifiers: UInt32

    /// Creates a descriptor for a registered Carbon hot key.
    /// - Parameters:
    ///   - keyCode: The Carbon virtual key code.
    ///   - modifiers: The OR-ed Carbon modifier mask.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
