import AppKit
import Bonsplit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import CmuxTerminal

func browserOmnibarSelectionDeltaForControlNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [.control] else { return nil }
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

func browserOmnibarShouldBypassShortcutRoutingForMarkedText(
    hasFocusedAddressBar: Bool,
    firstResponderHasMarkedText: Bool,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard hasFocusedAddressBar, firstResponderHasMarkedText else { return false }
    return !browserOmnibarNormalizedModifierFlags(flags).contains(.command)
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
        guard !isControlCharacterScalar(scalar) else { return false }
        return scalar.value < 0xF700 || scalar.value > 0xF8FF
    }
}

func browserOmnibarShouldContinueControlNavigationRepeat(flags: NSEvent.ModifierFlags) -> Bool {
    browserOmnibarNormalizedModifierFlags(flags) == [.control]
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

/// Returns true when a terminal arrow key-equivalent should be sent through keyDown.
func shouldDispatchTerminalArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsTerminal: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTerminal, !firstResponderHasMarkedText, (123...126).contains(keyCode) else { return false }
    return !browserOmnibarNormalizedModifierFlags(flags).contains(.command)
}

struct BrowserAddressBarTrackingContext {
    let trackedPanelMatchesWebView: Bool
    let omnibarResponderActive: Bool
    let preferredFocusIntentIsAddressBar: Bool
    let suppressesWebViewFocus: Bool
    let pointerInitiatedWebFocus: Bool
    let liveOmnibarFieldExists: Bool
}

/// Decision order:
/// 1. Reject WebView focus from another panel.
/// 2. Preserve if an omnibar responder is already active.
/// 3. Require address-bar focus intent.
/// 4. Let pointer-initiated WebView focus clear tracking.
/// 5. Preserve if WebView focus is suppressed or a live omnibar field exists.
func shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(
    _ context: BrowserAddressBarTrackingContext
) -> Bool {
    guard context.trackedPanelMatchesWebView else { return false }
    if context.omnibarResponderActive { return true }
    guard context.preferredFocusIntentIsAddressBar else { return false }
    guard !context.pointerInitiatedWebFocus else { return false }
    return context.suppressesWebViewFocus || context.liveOmnibarFieldExists
}

func shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsCommandPaletteFieldEditor: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsCommandPaletteFieldEditor else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 123 || keyCode == 124 else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    switch normalizedFlags {
    case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
        return true
    default:
        return false
    }
}

/// Whether an arrow keyDown belongs to a focused standalone editable text
/// responder (text-box input, file-preview editor, …) so it should be
/// forwarded to `firstResponder.keyDown` rather than swallowed by the original
/// `NSWindow.performKeyEquivalent`.
///
/// Owns the four arrows (keyCodes 123–126) for the modifier combos a text
/// editor handles itself: plain (move), Shift (extend selection), Option
/// (word/paragraph), and Command (line/document boundary) plus their Shift
/// combos. Cmd+Option+Arrow is excluded so it still reaches cmux's pane-focus
/// shortcuts. Marked text (IME composition) is left to the input method.
private func standaloneTextResponderOwnsArrowKeyDown(
    keyCode: UInt16,
    firstResponderHasMarkedText: Bool,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard !firstResponderHasMarkedText else { return false }
    guard (123...126).contains(keyCode) else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    switch normalizedFlags {
    case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
        return true
    default:
        return false
    }
}

func shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsTextBoxInput: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTextBoxInput else { return false }
    return standaloneTextResponderOwnsArrowKeyDown(
        keyCode: keyCode,
        firstResponderHasMarkedText: firstResponderHasMarkedText,
        flags: flags
    )
}

/// Whether an arrow keyDown should be forwarded straight to the focused
/// standalone editable text view instead of falling through to the original
/// `NSWindow.performKeyEquivalent`, which swallows plain arrows before the
/// view's `keyDown` runs.
///
/// This generalizes the per-surface arrow-forwarding seam (browser, omnibar,
/// command palette, text-box input) to cover the whole class of standalone
/// editable `NSTextView`s cmux hosts, the file-preview editor today, any
/// future one tomorrow. Field editors (the omnibar / command-palette / find
/// field editors) are excluded by the caller because they have their own
/// dedicated routing or work through the normal field-editor path. Shares the
/// keyCode/modifier policy with ``shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown``
/// via ``standaloneTextResponderOwnsArrowKeyDown(keyCode:firstResponderHasMarkedText:flags:)``.
func shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsEditableTextView: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsEditableTextView else { return false }
    return standaloneTextResponderOwnsArrowKeyDown(
        keyCode: keyCode,
        firstResponderHasMarkedText: firstResponderHasMarkedText,
        flags: flags
    )
}

/// Ctrl-N / Ctrl-P navigate the mention-completion popover (and emacs-style line
/// movement) inside the terminal textbox. Like plain arrows, the window's
/// `performKeyEquivalent` claims these before they reach the textbox `keyDown`, so
/// they must be routed to the first responder explicitly. Scoped to the textbox so
/// terminal/browser Ctrl-N/Ctrl-P are unaffected.
func shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
    charactersIgnoringModifiers: String?,
    firstResponderIsTextBoxInput: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTextBoxInput else { return false }
    guard !firstResponderHasMarkedText else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [.control] else { return false }
    let key = charactersIgnoringModifiers?.lowercased()
    return key == "n" || key == "p"
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

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
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
/// What a newly opened find bar starts with. Shared by the terminal and
/// browser find entrypoints so Cmd+F recovery stays consistent across
/// surfaces and honors `app.findRestoresLastSearch`.
struct FindSearchRecovery: Equatable {
    var needle: String
    var selectAll: Bool

    static func resolve(
        startsNewSearchSession: Bool,
        lastNeedle: String,
        defaults: UserDefaults = .standard
    ) -> FindSearchRecovery {
        let key = AppCatalogSection().findRestoresLastSearch
        let restoresLastSearch = defaults.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
        guard startsNewSearchSession, restoresLastSearch, !lastNeedle.isEmpty else {
            return FindSearchRecovery(needle: "", selectAll: false)
        }
        return FindSearchRecovery(needle: lastNeedle, selectAll: true)
    }
}

// Main-actor isolated: TerminalSurface.searchState carries the legacy
// main-thread-only contract as compiler-enforced isolation after the
// CmuxTerminal lift; both callers (TabManager, overlay tests) are @MainActor.
@MainActor
@discardableResult
func startOrFocusTerminalSearch(
    _ terminalSurface: TerminalSurface,
    initialNeedle: String = "",
    searchFocusNotifier: @escaping (TerminalSurface) -> Void = {
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: $0)
    }
) -> Bool {
    if terminalSurface.searchState != nil {
        if !initialNeedle.isEmpty { terminalSurface.searchState?.needle = initialNeedle }
        searchFocusNotifier(terminalSurface)
        return true
    }
    if terminalSurface.performBindingAction("start_search") {
        DispatchQueue.main.async { [weak terminalSurface] in
            guard let terminalSurface else { return }
            if let searchState = terminalSurface.searchState {
                if !initialNeedle.isEmpty { searchState.needle = initialNeedle }
            } else {
                terminalSurface.searchState = TerminalSurface.SearchState(needle: initialNeedle)
            }
            searchFocusNotifier(terminalSurface)
        }
        return true
    }
    terminalSurface.searchState = TerminalSurface.SearchState(needle: initialNeedle)
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

func cmuxIsWebInspectorClassName(_ className: String) -> Bool {
    className.contains("WKInspector") || className.contains("WebInspector")
}

func cmuxIsWebInspectorObject(_ object: NSObject) -> Bool {
    cmuxIsWebInspectorClassName(String(describing: type(of: object))) ||
        cmuxIsWebInspectorClassName(NSStringFromClass(type(of: object)))
}

private enum BrowserDocumentEditingCommandEquivalent: CaseIterable {
    case copy
    case cut
    case selectAll
    case italic

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
        case .italic:
            // Cmd+I is the universal italics command in web writing apps (Notion,
            // Google Docs, …). Let the focused editor handle it before the app's
            // menu/Show Notifications fallback, just like copy/cut/select-all
            // (issue #6776).
            return StoredShortcut(
                key: "i",
                command: true,
                shift: false,
                option: false,
                control: false,
                keyCode: 34
            )
        }
    }
}

func cmuxIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    if cmuxIsWebInspectorObject(responder) {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if cmuxIsWebInspectorObject(current) {
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
    inlineVSCodeURLMatcher: (URL?) -> Bool = { VSCodeServeWebController.shared.isServeWebURL($0) },
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

enum WindowMoveSuppressionReason: String {
    case folderDrag
    case bonsplitPaneTabDrag
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

func beginOrContinueWindowMoveSuppressionSequenceForEvent(
    window: NSWindow,
    event: NSEvent,
    pressedMouseButtons: Int = NSEvent.pressedMouseButtons
) -> WindowMoveSuppressionReason? {
    if let activeReason = activeWindowMoveSuppressionSequenceReason(window: window) {
        if event.type == .leftMouseDown {
            _ = finishWindowMoveSuppressionSequence(window: window)
        } else if event.type == .leftMouseUp || event.type == .leftMouseDragged || (pressedMouseButtons & 0x1) != 0 {
            ensureWindowMoveSuppressionSequenceIsImmovable(window: window)
            return activeReason
        } else {
            _ = finishWindowMoveSuppressionSequence(window: window)
        }
    }

    guard let reason = windowMoveSuppressionReason(window: window, event: event) else {
        return nil
    }
    return beginWindowMoveSuppressionSequence(window: window, reason: reason)
}

func shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: NSWindow, event: NSEvent) -> Bool {
    activeWindowMoveSuppressionSequenceReason(window: window) != nil && event.type == .leftMouseUp
}
