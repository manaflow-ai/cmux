import AppKit

#if DEBUG
func commandPaletteDiagnosticWindowSummary(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    let ident = window.identifier?.rawValue ?? "nil"
    return "num=\(window.windowNumber) ident=\(ident) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
}

func commandPaletteDiagnosticNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func commandPaletteDiagnosticModifierFlagsSummary(_ flags: NSEvent.ModifierFlags) -> String {
    let normalized = commandPaletteDiagnosticNormalizedModifierFlags(flags)
    var parts: [String] = []
    if normalized.contains(.command) { parts.append("cmd") }
    if normalized.contains(.shift) { parts.append("shift") }
    if normalized.contains(.option) { parts.append("opt") }
    if normalized.contains(.control) { parts.append("ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func commandPaletteDiagnosticKeyEventSummary(_ event: NSEvent) -> String {
    let chars = event.characters.map(commandPaletteDiagnosticTextMetadata) ?? "nil"
    let charsIgnoring = event.charactersIgnoringModifiers.map(commandPaletteDiagnosticTextMetadata) ?? "nil"
    return
        "type=\(event.type) keyCode=\(event.keyCode) flags=\(commandPaletteDiagnosticModifierFlagsSummary(event.modifierFlags)) " +
        "chars=\(chars) charsIgnoring=\(charsIgnoring)"
}

func commandPaletteDiagnosticTextMetadata(_ text: String) -> String {
    "present=\(text.isEmpty ? 0 : 1),utf8Bytes=\(text.utf8.count),utf16Units=\((text as NSString).length)"
}

func commandPaletteDiagnosticResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }

    let typeName = String(describing: type(of: responder))
    if let textView = responder as? NSTextView {
        let selection = textView.selectedRange()
        return "\(typeName){fieldEditor=\(textView.isFieldEditor ? 1 : 0) editable=\(textView.isEditable ? 1 : 0) selectable=\(textView.isSelectable ? 1 : 0) hidden=\(textView.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textView.string as NSString).length) sel=\(selection.location):\(selection.length)}"
    }

    if let textField = responder as? NSTextField {
        return "\(typeName){editable=\(textField.isEditable ? 1 : 0) enabled=\(textField.isEnabled ? 1 : 0) hidden=\(textField.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textField.stringValue as NSString).length)}"
    }

    if let view = responder as? NSView {
        return "\(typeName){hidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)}"
    }

    return typeName
}

let debugCommandPaletteWindowSummary = commandPaletteDiagnosticWindowSummary
let debugCommandPaletteModifierFlagsSummary = commandPaletteDiagnosticModifierFlagsSummary
let debugCommandPaletteKeyEventSummary = commandPaletteDiagnosticKeyEventSummary
let debugCommandPaletteTextMetadata = commandPaletteDiagnosticTextMetadata
let debugCommandPaletteResponderSummary = commandPaletteDiagnosticResponderSummary
#endif
