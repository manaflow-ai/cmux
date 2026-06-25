public import AppKit

/// The Cmd+Shift+V "paste as plain text" key command for the browser web view,
/// expressed purely as an `NSEvent` predicate.
///
/// The match is by hardware key position (`keyCode == 9`, the physical V key, so
/// it is keyboard-layout independent) plus the device-independent Command+Shift
/// modifier set, ignoring the numeric-pad, function, and caps-lock flags. It
/// carries no state and reads nothing from the web view, so it is safe to
/// evaluate off any actor. Mirrors the value-type precedent
/// ``BrowserWebViewBackgroundDrawPolicy``; the host app keeps the
/// `performKeyEquivalent`/`keyDown` call sites and all `@objc`/WKWebView
/// plumbing, forwarding the comparison here.
public struct BrowserPasteAsPlainTextKeyCommand: Sendable {
    /// Hardware key code for the V key (hardware position, layout-independent).
    public static let keyCode: UInt16 = 9

    public init() {}

    /// Whether the event is the Cmd+Shift+V paste-as-plain-text command.
    public func matches(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        return event.keyCode == Self.keyCode && normalizedFlags == [.command, .shift]
    }
}
