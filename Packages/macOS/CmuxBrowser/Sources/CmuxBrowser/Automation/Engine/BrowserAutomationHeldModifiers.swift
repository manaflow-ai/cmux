/// The modifier keys an automation client holds down on one page.
///
/// The DevTools protocol keeps no keyboard state: every key event carries its
/// own modifier mask. Separate `keydown Shift`, `press a`, `keyup Shift`
/// commands therefore need the client to remember what is held, as Puppeteer
/// does, so `a` arrives shifted.
public struct BrowserAutomationHeldModifiers: Equatable, Sendable {
    /// The modifiers currently held.
    public private(set) var held: BrowserKeyboardNativeModifiers = []

    public init() {}

    /// Records one key action and returns the modifiers held around it (before
    /// a modifier key's own change, which the event encoder adds itself).
    /// - Parameters:
    ///   - event: the key.
    ///   - action: what happens to it.
    /// - Returns: the modifiers to send with the event.
    public mutating func record(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> BrowserKeyboardNativeModifiers {
        let current = held
        guard let modifier = event.nativeKey?.modifierKey else { return current }
        switch action {
        case .keyDown:
            held.insert(modifier)
        case .keyUp:
            held.remove(modifier)
        case .press:
            break
        }
        return current
    }
}
