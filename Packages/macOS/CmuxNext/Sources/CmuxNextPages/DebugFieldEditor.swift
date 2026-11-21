#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextSettings

/// `debug.text_field` {text?, from?, to?, blur?, key?} (DEBUG builds): the text a person edits in the window's
/// focused native field (its field editor, or a text view that is first responder), for captures of a field's
/// typed text, caret and selection. `key` first activates the app and makes the window key, so the caret, the
/// selection and the focus ring draw as a person sees them. `text` replaces the field's text as typed input (the
/// field's delegate sees the change); `from` and `to` select characters `from` to `to` (`from == to`: the caret;
/// no `to`: the end; no `from`: the caret at the end). `blur` takes the keyboard from whatever has it. Answers the
/// field's class, its placeholder, its text and the selected range, or `error` when no text field has the keyboard.
@MainActor
public struct DebugFieldEditor {
    public init() {}
    public static func run(_ params: [String: JSONValue], window: NSWindow?) -> JSONValue {
        guard let window else { return .object(["error": .string("no window")]) }
        if params["key"]?.boolValue == true {
            NSApp.activate(); window.orderFrontRegardless() // focus-route: debug.text_field key is an explicit focus command (captures)
            window.makeKey()
        }
        if params["blur"]?.boolValue == true {
            // Nothing in the window has the keyboard, as after a click on empty chrome.
            return .object(["blurred": .bool(window.makeFirstResponder(nil))]) // focus-route: debug.text_field blur is an explicit focus command (captures)
        }
        guard let editor = window.firstResponder as? NSTextView else {
            return .object(["key": .bool(window.isKeyWindow),
                            "first_responder": .string(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")])
        }
        if let text = params["text"]?.stringValue {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        let length = (editor.string as NSString).length
        let from = min(max(params["from"]?.intValue ?? length, 0), length)
        let to = min(max(params["to"]?.intValue ?? length, from), length)
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        editor.scrollRangeToVisible(editor.selectedRange())
        let field = editor.isFieldEditor ? editor.delegate as? NSTextField : nil
        return .object([
            "field": .string(String(describing: type(of: field ?? editor))),
            "placeholder": .string(field?.placeholderString ?? ""),
            "text": .string(editor.string),
            "selection": .array([.number(Double(from)), .number(Double(to))]),
            "key": .bool(window.isKeyWindow),
        ])
    }
}
#endif
