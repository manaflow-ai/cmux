#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextDesign
public import CmuxNextSettings

/// `debug.text_field` {focus?, text?, from?, to?, blur?, key?, appearance?} (DEBUG builds): the text a person edits in the window's
/// focused native field (its field editor, or a text view that is first responder), for captures of a field's
/// typed text, caret and selection. `key` first activates the app and makes the window key, so the caret, the
/// selection and the focus ring draw as a person sees them. `text` replaces the field's text as typed input (the
/// field's delegate sees the change); `from` and `to` select characters `from` to `to` (`from == to`: the caret;
/// no `to`: the end; no `from`: the caret at the end). `appearance` (`light`, `dark`, `system`) sets the app's
/// appearance as debug.appearance does and answers only the effective one. `focus` gives the keyboard to the first
/// shown view whose accessibility identifier, class or placeholder it names (or its first descendant that takes it). `blur` takes the keyboard from whatever has it. Answers the
/// field's class, its placeholder, its text and the selected range, or `error` when no text field has the keyboard.
@MainActor
public struct DebugFieldEditor {
    public init() {}
    public static func run(_ params: [String: JSONValue], window: NSWindow?) -> JSONValue {
        guard let window else { return .object(["error": .string("no window")]) }
        if let mode = params["appearance"]?.stringValue {
            // As debug.appearance, whose answer names the bundle's path (a capture's privacy check refuses it).
            NSApp.appearance = mode == "system" ? nil : NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            return .object(["appearance": .string(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light")])
        }
        if params["key"]?.boolValue == true {
            // A capture launches with CMUX_NEXT_NO_ACTIVATE=1, so no window is key and no caret, selection or focus ring
            // draws. `key` lifts that for the rest of this run, on a whole-host capture nobody else shares.
            WindowPlacement.noActivate = false
            (NSApp as? any ActivationRefusing)?.refusesActivation = false
            NSApp.activate(ignoringOtherApps: true) // focus-route: debug.text_field key is an explicit focus command (captures)
            window.makeKeyAndOrderFront(nil) // focus-route: debug.text_field key is an explicit focus command (captures)
        }
        if params["blur"]?.boolValue == true {
            // Nothing in the window has the keyboard, as after a click on empty chrome.
            return .object(["blurred": .bool(window.makeFirstResponder(nil))]) // focus-route: debug.text_field blur is an explicit focus command (captures)
        }
        if let target = params["focus"]?.stringValue {
            // The first shown view that takes the keyboard and whose accessibility identifier, class or placeholder is
            // `target`, as a person's click in it (a capture's click needs window geometry that moves with the layout).
            guard let view = Self.view(target, in: window.contentView?.superview ?? window.contentView) else {
                return .object(["error": .string("no shown field matches \(target)")])
            }
            window.makeFirstResponder(view) // focus-route: debug.text_field focus is an explicit focus command (captures)
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

    /// The first shown view named `target` (nil: any view that takes the keyboard); one that does not take it itself
    /// (a pane holding a WebKit or Chromium page) gives its first descendant that does.
    private static func view(_ target: String?, in root: NSView?) -> NSView? {
        guard let root, !root.isHidden else { return nil }
        guard let target else { return root.acceptsFirstResponder ? root : root.subviews.lazy.compactMap { view(nil, in: $0) }.first }
        if root.accessibilityIdentifier() == target || String(describing: type(of: root)) == target
            || (root as? NSTextField)?.placeholderString == target { return view(nil, in: root) }
        return root.subviews.lazy.compactMap { view(target, in: $0) }.first
    }
}
#endif
