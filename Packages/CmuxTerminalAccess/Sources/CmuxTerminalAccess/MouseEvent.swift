// SPDX-License-Identifier: MIT

import Foundation

/// One mouse event in *cell* coordinates. ghostty encodes the outgoing
/// bytes according to the surface's active mouse mode (DEC 1000/1002/1003
/// × 1006 SGR). Per D16, the cmux dispatch path must NOT synthesize
/// NSEvents.
public struct MouseEvent: Hashable, Sendable {
    /// The action kind (press/release/move/scroll).
    public let action: MouseAction
    /// The button involved, or `nil` for `move` / `scroll` events with
    /// no button.
    public let button: MouseButton?
    /// Zero-based column.
    public let x: Int
    /// Zero-based row.
    public let y: Int
    /// Modifier flags held during the event.
    public let mods: Set<KeyMod>
    /// Scroll delta in cells (negative is up); `0` for non-scroll events.
    public let scrollDy: Int

    /// Creates a mouse event from its fields.
    public init(
        action: MouseAction,
        button: MouseButton?,
        x: Int,
        y: Int,
        mods: Set<KeyMod>,
        scrollDy: Int
    ) {
        self.action = action
        self.button = button
        self.x = x
        self.y = y
        self.mods = mods
        self.scrollDy = scrollDy
    }

    /// Parse failure modes for ``parse(_:)``.
    public enum ParseError: Error, Equatable {
        /// A required field was missing from the input object.
        case missing(field: String)
        /// The `action` field was not a known ``MouseAction`` value.
        case unknownAction(String)
        /// The `button` field was not a known ``MouseButton`` value.
        case unknownButton(String)
        /// A `mods` entry was not a known ``KeyMod`` value.
        case unknownModifier(String)
    }

    /// Parse a `[String: Any]` JSON object (already `JSONSerialization`ed)
    /// into a ``MouseEvent``. Throwing only — wired into the HTTP input
    /// decoder in Phase 1, which maps this into
    /// ``TerminalAccessError/badRequest(reason:)``.
    ///
    /// - Throws: ``ParseError`` describing the failure shape.
    public static func parse(_ obj: [String: Any]) throws -> MouseEvent {
        guard let actionRaw = obj["action"] as? String else {
            throw ParseError.missing(field: "action")
        }
        guard let action = MouseAction(rawValue: actionRaw) else {
            throw ParseError.unknownAction(actionRaw)
        }
        var button: MouseButton? = nil
        if let b = obj["button"] as? String {
            guard let parsed = MouseButton(rawValue: b) else {
                throw ParseError.unknownButton(b)
            }
            button = parsed
        }
        guard let x = obj["x"] as? Int else { throw ParseError.missing(field: "x") }
        guard let y = obj["y"] as? Int else { throw ParseError.missing(field: "y") }
        var mods: Set<KeyMod> = []
        if let m = obj["mods"] as? [String] {
            for s in m {
                guard let mod = KeyMod(rawValue: s) else {
                    throw ParseError.unknownModifier(s)
                }
                mods.insert(mod)
            }
        }
        let dy = (obj["scrollDy"] as? Int) ?? 0
        return MouseEvent(action: action, button: button, x: x, y: y, mods: mods, scrollDy: dy)
    }
}
