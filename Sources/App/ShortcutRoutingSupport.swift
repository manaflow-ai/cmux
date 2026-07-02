import CmuxSettings
import AppKit
import Bonsplit
import CmuxBrowser
import CmuxCommandPalette
import CmuxWindowing
import CmuxWorkspaces
import Foundation
import CmuxTerminal

func browserOmnibarSelectionDeltaForControlNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    flags.browserOmnibarSelectionDeltaForControlNavigation(
        hasFocusedAddressBar: hasFocusedAddressBar,
        chars: chars
    )
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    flags.browserOmnibarSelectionDeltaForArrowNavigation(
        hasFocusedAddressBar: hasFocusedAddressBar,
        keyCode: keyCode
    )
}

func browserOmnibarShouldBypassShortcutRoutingForMarkedText(
    hasFocusedAddressBar: Bool,
    firstResponderHasMarkedText: Bool,
    flags: NSEvent.ModifierFlags
) -> Bool {
    flags.browserOmnibarShouldBypassShortcutRoutingForMarkedText(
        hasFocusedAddressBar: hasFocusedAddressBar,
        firstResponderHasMarkedText: firstResponderHasMarkedText
    )
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func shortcutRoutingShouldBypassForPrintableOptionText(
    event: NSEvent,
    textInputCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.textInputCharacter(forKeyCode:modifierFlags:)
) -> Bool {
    guard event.type == .keyDown else { return false }
    let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
    guard normalizedFlags.contains(.option),
          !normalizedFlags.contains(.command),
          !normalizedFlags.contains(.control) else {
        return false
    }

    if shortcutRoutingTextIsPrintable(event.characters) {
        return true
    }

    return shortcutRoutingTextIsPrintable(
        textInputCharacterProvider(event.keyCode, event.modifierFlags)
    )
}

private func shortcutRoutingTextIsPrintable(_ text: String?) -> Bool {
    guard let text, !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        guard !scalar.isTerminalControlCharacter else { return false }
        return scalar.value < 0xF700 || scalar.value > 0xF8FF
    }
}

func browserOmnibarShouldContinueControlNavigationRepeat(flags: NSEvent.ModifierFlags) -> Bool {
    flags.browserOmnibarShouldContinueControlNavigationRepeat
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    flags.browserOmnibarShouldSubmitOnReturn
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
    // Keep browser Return forwarding narrow: only plain/Shift Return is submit;
    // Command-modified Return is reserved for app shortcuts like Toggle Pane Zoom.
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
    guard (123...126).contains(keyCode) else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)

    if normalizedFlags.isEmpty {
        return true
    }

    // Keep modified arrow routing narrow to avoid stealing cmux shortcuts such
    // as Cmd+Option+Arrow pane focus. Browser document editors own Cmd+Up/Down
    // as trusted keyDown navigation to the start/end of the document.
    return normalizedFlags == [.command] && (keyCode == 125 || keyCode == 126)
}

func shouldDispatchBrowserOmnibarArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowserOmnibar: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowserOmnibar else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard (123...126).contains(keyCode) else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags.isEmpty
}

func shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
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
        case 49, 51, 117, 123, 124:
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

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> BrowserZoomShortcutAction? {
    BrowserZoomShortcutAction.resolve(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars,
        layoutCharacter: { KeyboardLayout.character(forKeyCode: $0) }
    )
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

private enum BrowserFindCommandEquivalent: CaseIterable {
    case find
    case findInDirectory
    case findNext
    case findPrevious
    case hideFind
    case useSelection

    var action: KeyboardShortcutSettings.Action {
        switch self {
        case .find: return .find
        case .findInDirectory: return .findInDirectory
        case .findNext: return .findNext
        case .findPrevious: return .findPrevious
        case .hideFind: return .hideFind
        case .useSelection: return .useSelectionForFind
        }
    }

    var keepsCmuxBrowserFindBarOwnershipWhenVisible: Bool {
        switch self {
        case .find, .findNext, .findPrevious, .hideFind:
            return true
        case .findInDirectory, .useSelection:
            return false
        }
    }
}

private enum BrowserDocumentEditingCommandEquivalent: CaseIterable {
    case copy
    case cut
    case selectAll

    var shortcut: StoredShortcut {
        switch self {
        case .copy:
            return StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false,
                keyCode: 8
            )
        case .cut:
            return StoredShortcut(
                key: "x",
                command: true,
                shift: false,
                option: false,
                control: false,
                keyCode: 7
            )
        case .selectAll:
            return StoredShortcut(
                key: "a",
                command: true,
                shift: false,
                option: false,
                control: false,
                keyCode: 0
            )
        }
    }
}

func cmuxIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    if responder.isCmuxWebInspectorObject {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if current.isCmuxWebInspectorObject {
            return true
        }
        node = current.superview
        hops += 1
    }
    return false
}

private func browserFindCommandEquivalent(
    for event: NSEvent,
    shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut = KeyboardShortcutSettings.shortcut(for:)
) -> BrowserFindCommandEquivalent? {
    BrowserFindCommandEquivalent.allCases.first { command in
        shortcutForAction(command.action).matches(event: event)
    }
}

private func browserDocumentEditingCommandEquivalent(for event: NSEvent) -> BrowserDocumentEditingCommandEquivalent? {
    BrowserDocumentEditingCommandEquivalent.allCases.first { command in
        command.shortcut.matches(event: event)
    }
}

/// For browser content, let the focused document/editor try native editing commands
/// before cmux's menu fallback. Rich web apps often implement copy/cut/select-all
/// in contentEditable handlers that AppKit's Edit menu path cannot reproduce.
func shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(
    _ event: NSEvent,
    responder: NSResponder? = nil
) -> Bool {
    guard browserDocumentEditingCommandEquivalent(for: event) != nil else {
        return false
    }

    if cmuxIsLikelyWebInspectorResponder(responder) {
        return false
    }

    return true
}

/// For browser content, let the page try browser-local Find-family commands before cmux's menu fallback.
/// Cmd+F is excluded because cmux chooses terminal, browser, or right-sidebar
/// find from the current focus owner.
func shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
    _ event: NSEvent,
    responder: NSResponder? = nil,
    owningWebView: CmuxWebView? = nil
) -> Bool {
    guard let shortcut = browserFindCommandEquivalent(for: event) else {
        return false
    }

    if case .find = shortcut {
        return false
    }

    if case .findInDirectory = shortcut {
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

func shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
    _ event: NSEvent,
    pageURL: URL?,
    inlineVSCodeURLMatcher: (URL?) -> Bool = { AppDelegate.shared?.vscodeServeWebController.isServeWebURL($0) ?? false },
    shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut = KeyboardShortcutSettings.shortcut(for:)
) -> Bool {
    guard inlineVSCodeURLMatcher(pageURL) else { return false }
    return shortcutForAction(.commandPalette).matches(event: event)
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
    if let owner = cmuxTrackedFindFieldEditorOwner(editor) { return owner }
    var current = editor.nextResponder
    while let next = current {
        if let view = next as? NSView {
            return view
        }
        current = next.nextResponder
    }

    return editor.superview
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
    BrowserZoomShortcutAction.traceCandidate(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars,
        layoutCharacter: { KeyboardLayout.character(forKeyCode: $0) }
    )
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    BrowserZoomShortcutAction.traceFlagsString(flags)
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    BrowserZoomShortcutAction.traceActionString(action)
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

func shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown else {
        return false
    }

    return BonsplitTabItemHitRegionRegistry.containsWindowPoint(event.locationInWindow, in: window)
}

func windowMoveSuppressionReason(window: NSWindow, event: NSEvent) -> WindowMoveSuppressionReason? {
    if shouldSuppressWindowMoveForFolderDrag(window: window, event: event) {
        return .folderDrag
    }
    if shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event) {
        return .bonsplitPaneTabDrag
    }
    return nil
}

@MainActor
func beginOrContinueWindowMoveSuppressionSequenceForEvent(
    window: NSWindow,
    event: NSEvent,
    pressedMouseButtons: Int = NSEvent.pressedMouseButtons
) -> WindowMoveSuppressionReason? {
    if let activeReason = window.activeWindowMoveSuppressionSequenceReason {
        if event.type == .leftMouseDown {
            _ = window.finishWindowMoveSuppressionSequence()
        } else if event.type == .leftMouseUp || event.type == .leftMouseDragged || (pressedMouseButtons & 0x1) != 0 {
            window.ensureWindowMoveSuppressionSequenceIsImmovable()
            return activeReason
        } else {
            _ = window.finishWindowMoveSuppressionSequence()
        }
    }

    guard let reason = windowMoveSuppressionReason(window: window, event: event) else {
        return nil
    }
    return window.beginWindowMoveSuppressionSequence(reason: reason)
}

@MainActor
func shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: NSWindow, event: NSEvent) -> Bool {
    window.activeWindowMoveSuppressionSequenceReason != nil && event.type == .leftMouseUp
}
