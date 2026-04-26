import AppKit
import Foundation

func browserOmnibarSelectionDeltaForCommandNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
    guard isCommandOrControlOnly else { return nil }
    if chars == "n" { return 1 }
    if chars == "p" { return -1 }
    return nil
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [] else { return nil }
    switch keyCode {
    case 125: return 1
    case 126: return -1
    default: return nil
    }
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags == [] || normalizedFlags == [.shift]
}

func browserResponderHasMarkedText(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }

    // During IME composition, Return/Enter belongs to the text system so the
    // candidate list can commit or confirm the marked text.
    if let textInputClient = responder as? NSTextInputClient {
        return textInputClient.hasMarkedText()
    }

    if let textField = responder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }

    return false
}

func shouldDispatchBrowserReturnViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 36 || keyCode == 76 else { return false }
    // Keep browser Return forwarding narrow: only plain/Shift Return should be
    // treated as submit-intent. Command-modified Return is reserved for app shortcuts
    // like Toggle Pane Zoom (Cmd+Shift+Enter).
    return browserOmnibarShouldSubmitOnReturn(flags: flags)
}

func shouldDispatchBrowserArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 125 || keyCode == 126 else { return false }

    // Keep this narrow to avoid stealing app/browser shortcuts that layer onto
    // modified arrow keys. Plain up/down should always flow through keyDown so
    // web content such as Google Docs receives the event directly.
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    return normalizedFlags.isEmpty
}

func shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    guard normalizedFlags == [.command, .control] else { return false }
    let normalizedChars = chars.lowercased()
    if normalizedChars == "f" {
        return true
    }
    let charsAreControlSequence = !normalizedChars.isEmpty
        && normalizedChars.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    if !normalizedChars.isEmpty && !charsAreControlSequence {
        return false
    }

    // Fallback to layout translation only when characters are unavailable (for
    // synthetic/key-equivalent paths that can report an empty string).
    if let translatedCharacter = layoutCharacterProvider(keyCode, flags), !translatedCharacter.isEmpty {
        return translatedCharacter == "f"
    }

    // Keep ANSI fallback as a final safety net when layout translation is unavailable.
    return keyCode == 3
}

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    let normalizedChars = chars.lowercased()

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if normalizedFlags == [.control] {
        // Control modifiers can surface as either printable chars or ASCII control chars.
        // Keep Emacs-style next/previous navigation, but leave other control bindings
        // (for example Ctrl+K text editing in the palette search field) to AppKit.
        if keyCode == 45 || normalizedChars == "n" || normalizedChars == "\u{0e}" { return 1 }    // Ctrl+N
        if keyCode == 35 || normalizedChars == "p" || normalizedChars == "\u{10}" { return -1 }   // Ctrl+P
    }

    return nil
}

func shouldRouteCommandPaletteSelectionNavigation(
    delta: Int?,
    isInteractive: Bool,
    usesInlineTextHandling: Bool
) -> Bool {
    guard delta != nil, isInteractive else { return false }
    return !usesInlineTextHandling
}

func shouldConsumeShortcutWhileCommandPaletteVisible(
    isCommandPaletteVisible: Bool,
    normalizedFlags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard isCommandPaletteVisible else { return false }

    // Escape dismisses the palette, and must not leak through to the
    // underlying terminal or browser content.
    if normalizedFlags.isEmpty, keyCode == 53 {
        return true
    }

    guard normalizedFlags.contains(.command) else { return false }

    let normalizedChars = chars.lowercased()

    if normalizedFlags == [.command] {
        if normalizedChars == "a"
            || normalizedChars == "c"
            || normalizedChars == "v"
            || normalizedChars == "x"
            || normalizedChars == "z"
            || normalizedChars == "y" {
            return false
        }

        switch keyCode {
        case 51, 117, 123, 124:
            return false
        default:
            break
        }
    }

    if normalizedFlags == [.command, .shift], normalizedChars == "z" {
        return false
    }

    return true
}

func shouldSubmitCommandPaletteWithReturn(
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags,
    mode: String
) -> Bool {
    guard keyCode == 36 || keyCode == 76 else { return false }
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    if normalizedFlags.isEmpty {
        return true
    }
    if normalizedFlags == [.shift] {
        return mode != "workspace_description_input"
    }
    return false
}

func commandPaletteFieldEditorHasMarkedText(in window: NSWindow) -> Bool {
    if let editor = window.firstResponder as? NSTextView {
        return editor.hasMarkedText()
    }
    if let textField = window.firstResponder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }
    return false
}

func shouldHandleCommandPaletteShortcutEvent(
    _ event: NSEvent,
    paletteWindow: NSWindow?
) -> Bool {
    guard let paletteWindow else { return false }
    if let eventWindow = event.window {
        return eventWindow === paletteWindow
    }
    let eventWindowNumber = event.windowNumber
    if eventWindowNumber > 0 {
        return eventWindowNumber == paletteWindow.windowNumber
    }
    if let keyWindow = NSApp.keyWindow {
        return keyWindow === paletteWindow
    }
    return false
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]

    static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }
    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )

    if keys.contains("=") || keys.contains("+") || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if keys.contains("-") || keys.contains("_") || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if keys.contains("0") || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func browserZoomShortcutKeyCandidates(
    chars: String,
    literalChars: String?,
    keyCode: UInt16
) -> Set<String> {
    var keys: Set<String> = [chars.lowercased()]

    if let literalChars, !literalChars.isEmpty {
        keys.insert(literalChars.lowercased())
    }

    if let layoutChar = KeyboardLayout.character(forKeyCode: keyCode), !layoutChar.isEmpty {
        keys.insert(layoutChar)
    }

    return keys
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}

func focusedTerminalKeyRepairNeeded(
    responderIsWindow: Bool,
    responderHasViableKeyRoutingOwner: Bool,
    responderMatchesPreferredKeyboardFocus: Bool
) -> Bool {
    responderIsWindow || !responderHasViableKeyRoutingOwner || !responderMatchesPreferredKeyboardFocus
}

func shouldRepairFocusedTerminalCommandEquivalentInputs(
    flags: NSEvent.ModifierFlags,
    responderIsWindow: Bool,
    responderHasViableKeyRoutingOwner: Bool
) -> Bool {
    let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
    guard normalizedFlags.contains(.command) else { return false }
    // Command shortcuts should only repair genuinely broken responder states.
    // If another live view already owns first responder, let menu routing use
    // that responder rather than retargeting to the selected terminal pane.
    return responderIsWindow || !responderHasViableKeyRoutingOwner
}

func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars
    ) != nil
}

@discardableResult
func startOrFocusTerminalSearch(
    _ terminalSurface: TerminalSurface,
    searchFocusNotifier: @escaping (TerminalSurface) -> Void = {
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: $0)
    }
) -> Bool {
    if terminalSurface.searchState != nil {
        searchFocusNotifier(terminalSurface)
        return true
    }

    if terminalSurface.performBindingAction("start_search") {
        DispatchQueue.main.async { [weak terminalSurface] in
            guard let terminalSurface, terminalSurface.searchState == nil else { return }
            terminalSurface.searchState = TerminalSurface.SearchState()
            searchFocusNotifier(terminalSurface)
        }
        return true
    }

    terminalSurface.searchState = TerminalSurface.SearchState()
    searchFocusNotifier(terminalSurface)
    return true
}

/// Let AppKit own native Cmd+` window cycling so key-window changes do not
/// re-enter our direct-to-menu shortcut path.
func shouldRouteCommandEquivalentDirectlyToMainMenu(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) else { return false }

    let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
    if event.keyCode == 50,
       normalizedFlags == [.command] || normalizedFlags == [.command, .shift] {
        return false
    }

    return true
}

private enum BrowserFindCommandEquivalent {
    case find
    case findNext
    case findPrevious
    case hideFind
    case useSelection

    var keepsCmuxBrowserFindBarOwnershipWhenVisible: Bool {
        switch self {
        case .find, .findNext, .findPrevious, .hideFind:
            return true
        case .useSelection:
            return false
        }
    }
}

func cmuxIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    let responderType = String(describing: type(of: responder))
    if responderType.contains("WKInspector") {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if String(describing: type(of: current)).contains("WKInspector") {
            return true
        }
        node = current.superview
        hops += 1
    }
    return false
}

private func browserFindCommandEquivalent(for event: NSEvent) -> BrowserFindCommandEquivalent? {
    let flags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])

    let normalizedChars = KeyboardLayout.normalizedCharacters(for: event).lowercased()
    let hasSingleASCIIShortcutChar =
        normalizedChars.count == 1 && normalizedChars.allSatisfy(\.isASCII)
    let producedAnyASCIIShortcutChar = normalizedChars.contains(where: \.isASCII)
    func matches(_ chars: String, keyCode: UInt16) -> Bool {
        if hasSingleASCIIShortcutChar {
            return normalizedChars == chars
        }
        if !producedAnyASCIIShortcutChar {
            return event.keyCode == keyCode
        }
        return false
    }

    switch flags {
    case [.command]:
        if matches("e", keyCode: 14) { // kVK_ANSI_E
            return .useSelection
        }
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .find
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findNext
        }
        return nil
    case [.command, .shift]:
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .hideFind
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findPrevious
        }
        return nil
    default:
        return nil
    }
}

/// For browser content, let the page try the Find command family before cmux's menu fallback.
/// This preserves native web-app shortcuts like VS Code's Cmd+F while still allowing cmux's
/// browser find overlay to keep owning its visible Find UI shortcuts.
func shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
    _ event: NSEvent,
    responder: NSResponder? = nil,
    owningWebView: CmuxWebView? = nil
) -> Bool {
    guard let shortcut = browserFindCommandEquivalent(for: event) else {
        return false
    }

    if cmuxIsLikelyWebInspectorResponder(responder) {
        return false
    }

    if shortcut.keepsCmuxBrowserFindBarOwnershipWhenVisible,
       let owningWebView {
        let browserFindBarIsVisible = MainActor.assumeIsolated {
            AppDelegate.shared?.browserFindBarIsVisible(for: owningWebView) == true
        }
        if browserFindBarIsVisible {
            return false
        }
    }

    return true
}

func cmuxOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView {
        if textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView),
           let ghosttyView = cmuxOwningGhosttyView(for: ownerView) {
            return ghosttyView
        }
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

func cmuxFieldEditorOwnerView(_ editor: NSTextView) -> NSView? {
    guard editor.isFieldEditor else { return nil }

    var current = editor.nextResponder
    while let next = current {
        if let view = next as? NSView {
            return view
        }
        current = next.nextResponder
    }

    return editor.superview
}

let cmuxRightSidebarExtensionHostContainerIdentifier =
    NSUserInterfaceItemIdentifier("cmux.rightSidebar.extensionHost.container")

func cmuxRightSidebarExtensionHostOwnsResponder(
    _ responder: NSResponder?,
    in window: NSWindow? = nil
) -> Bool {
    guard let responder else { return false }

    let ownerView: NSView?
    if let textView = responder as? NSTextView, textView.isFieldEditor {
        ownerView = cmuxFieldEditorOwnerView(textView) ?? textView
    } else {
        ownerView = responder as? NSView
    }

    guard let ownerView else { return false }
    if let window, ownerView.window !== window { return false }
    return cmuxRightSidebarExtensionHostAncestor(for: ownerView) != nil
}

func cmuxRightSidebarExtensionHostContains(windowPoint: NSPoint, in window: NSWindow) -> Bool {
    guard let contentView = window.contentView else { return false }
    return cmuxRightSidebarExtensionHost(atWindowPoint: windowPoint, in: contentView) != nil
}

private func cmuxRightSidebarExtensionHostAncestor(for view: NSView) -> NSView? {
    var current: NSView? = view
    while let candidate = current {
        if candidate.identifier == cmuxRightSidebarExtensionHostContainerIdentifier {
            return candidate
        }
        current = candidate.superview
    }
    return nil
}

private func cmuxRightSidebarExtensionHost(atWindowPoint windowPoint: NSPoint, in view: NSView) -> NSView? {
    guard !view.isHidden else { return nil }

    let localPoint = view.convert(windowPoint, from: nil)
    guard view.bounds.contains(localPoint) else { return nil }

    if view.identifier == cmuxRightSidebarExtensionHostContainerIdentifier {
        return view
    }

    for subview in view.subviews.reversed() {
        if let host = cmuxRightSidebarExtensionHost(atWindowPoint: windowPoint, in: subview) {
            return host
        }
    }

    return nil
}

private func cmuxOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        current = candidate.superview
    }

    return nil
}

#if DEBUG
func browserZoomShortcutTraceCandidate(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    guard normalizedFlags.contains(.command) else { return false }

    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )
    if keys.contains("=") || keys.contains("+") || keys.contains("-") || keys.contains("_") || keys.contains("0") {
        return true
    }
    switch keyCode {
    case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
        return true
    default:
        return false
    }
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    var parts: [String] = []
    if normalizedFlags.contains(.command) { parts.append("Cmd") }
    if normalizedFlags.contains(.shift) { parts.append("Shift") }
    if normalizedFlags.contains(.option) { parts.append("Opt") }
    if normalizedFlags.contains(.control) { parts.append("Ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    guard let action else { return "none" }
    switch action {
    case .zoomIn: return "zoomIn"
    case .zoomOut: return "zoomOut"
    case .reset: return "reset"
    }
}
#endif

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let contentPoint = contentView.convert(event.locationInWindow, from: nil)
    let hitView = contentView.hitTest(contentPoint)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}
