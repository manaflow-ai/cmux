public import Foundation

/// What an agent's type or key input types: the `typing` object of an
/// `automation.input` event (schemas/automation-input/event.schema.json),
/// which the browser host's gate fills before a secret resolves. The app
/// shows it next to the agent cursor (``AgentKeystrokeCaption``).
///
/// The vendored `AutomationInputEvent` decoder (cmux-cua) does not know
/// the field yet, so ``AgentCursorInputBridge`` takes it out of the event
/// before decoding and hands it on beside the event.
public struct AgentTyping: Sendable, Equatable {
    /// The typed text, or the text a key press types. Dots when `masked`.
    public var text: String?
    /// The DOM key value of a key event (`Enter`, `a`).
    public var key: String?
    /// Held modifiers (`Alt`, `Control`, `Meta`, `Shift`).
    public var modifiers: [String]
    /// The host hid the text (a secret, a password field, a field it could
    /// not see into).
    public var masked: Bool
    /// The text replaces the field's value (`locator.fill`).
    public var replace: Bool

    /// - Parameters:
    ///   - text: The typed text, dots when masked.
    ///   - key: The DOM key value of a key event.
    ///   - modifiers: Held modifiers of a key event.
    ///   - masked: Whether the host hid the text.
    ///   - replace: Whether the text replaces the field's value.
    public init(text: String? = nil, key: String? = nil, modifiers: [String] = [], masked: Bool = false,
                replace: Bool = false) {
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.masked = masked
        self.replace = replace
    }

    /// The most characters one event carries (`MAX_TYPED_CHARS` in the host).
    public static let maxTextLength = 64

    /// Reads a `typing` object; nil for anything the schema rejects (an
    /// unknown field, a wrong type, a text longer than ``maxTextLength``).
    ///
    /// - Parameter raw: The JSON value of the event's `typing` field.
    /// - Returns: The typing, or nil when it is invalid.
    public static func parse(_ raw: Any) -> AgentTyping? {
        guard let object = raw as? [String: Any] else { return nil }
        let allowed: Set<String> = ["text", "key", "modifiers", "masked", "replace"]
        guard object.keys.allSatisfy(allowed.contains) else { return nil }
        var typing = AgentTyping()
        if let text = object["text"] {
            guard let text = text as? String, text.count <= maxTextLength else { return nil }
            typing.text = text
        }
        if let key = object["key"] {
            guard let key = key as? String, !key.isEmpty else { return nil }
            typing.key = key
        }
        if let modifiers = object["modifiers"] {
            let names: Set<String> = ["Alt", "Control", "Meta", "Shift"]
            guard let list = modifiers as? [String], list.allSatisfy(names.contains) else { return nil }
            typing.modifiers = list
        }
        for (field, path) in [("masked", \AgentTyping.masked), ("replace", \AgentTyping.replace)] {
            guard let value = object[field] else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            typing[keyPath: path] = number.boolValue
        }
        return typing
    }
}
