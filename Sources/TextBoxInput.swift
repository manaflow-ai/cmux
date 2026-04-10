/*
TextBoxInput.swift

# TextBox Input Mode

Provides a native text editing experience for terminal input that
terminal emulators typically struggle with.

## Rationale

ghostty (libghostty)'s key input path has limitations with IME,
macOS standard keybindings, and system clipboard operations. TextBox
handles these natively via AppKit and sends only committed text to the
terminal. Shell history, tab completion, and Ctrl+key commands are
transparently forwarded while keeping focus in the TextBox, so users
get a seamless experience without being aware of two input modes.

## Features

### F1. Native Text Editing
Full macOS standard operations: Cmd+A (select all), Cmd+C/V/X (copy/paste/cut),
Cmd+Z/Shift+Cmd+Z (undo/redo), Option+Arrow (word navigation), mouse selection,
double-click word select, triple-click line select.

### F2. IME Support
Input methods (Japanese, Chinese, Korean, etc.) work correctly via NSTextView's
built-in marked text handling. Composition is not interrupted by terminal updates.

### F3. Multi-line Input
Insert newlines for multi-line text submission.
Default: Enter = send, Shift+Enter = newline (reversible in settings).

### F4. Auto-grow
Text box grows with content (1–8 visible lines), then scrolls internally.
Shrinks back to minimum after submit.

### F5. Key Routing
All rules are defined in `TextBoxKeyRouting` as a centralized table.
See the rule table above that enum for the full specification.
- Rule 1: Emacs editing (Ctrl+A/E/F/B/N/P/K/H) — handled by NSTextView
- Rule 2: Ctrl+other — forwarded to terminal (keep focus)
- Rule 3: "/" prefix — forwarded to terminal + focus terminal (empty, Claude Code/Codex)
- Rule 4: "@" prefix — forwarded to terminal + focus terminal (empty, Claude Code/Codex)
- Rule 5: "?" key — forwarded as raw event (empty, Claude Code/Codex, keep focus)
- Rule 6/7: Return/Shift+Return — submit or newline (setting-dependent)
- Rule 8: Escape — focus terminal or send ESC (setting-dependent)
- Rule 9: ↑ ↓ ← → Tab Backspace — forwarded to terminal when empty (keep focus)
- Rule 10: Fallback — default TextBox text input

### F6. Theme Sync
Matches terminal background/foreground colors (via Ghostty runtime config),
font size, background-opacity, and selection colors (inverted fg/bg).

### F7. Toggle Shortcut
Cmd+Option+B to toggle display or focus (configurable in Settings).
Default behavior: Toggle Focus (keep TextBox visible, swap focus).
Scope: all tabs toggle simultaneously.

### F8. Drag & Drop
Drop files/folders from Finder onto the TextBox to insert shell-escaped paths.
Multiple files are space-separated. Dropped text is selected for easy review.

### F9. Placeholder
Shows dynamic hint text when empty ("Commands or prompts here…")
with the current send key (Return or Shift+Return) based on settings.

### F10. Send Button
Paperplane icon button with hover/press highlight. Submits TextBox content.

### F11. Focus Guards
Terminal focus-restore mechanisms (ensureFocus, applyFirstResponder) skip
stealing focus when an InputTextView is the current first responder.

### F12. App Detection
Detects Claude Code and Codex by matching terminal tab title (regex,
case-insensitive). Claude Code is also detected when the title starts
with "✱" or "✳" (icon prefix) or "⠂" (thinking indicator).
Used to enable prefix/key forwarding (Rules 3–5).

### F13. Bracket Paste Submission
Text is sent via PTY bracket paste, then Return is sent as a separate
synthetic key event after a 200ms delay. This ensures apps using bracket
paste mode (zsh, Claude CLI) process the paste before receiving Return.

### F14. Per-panel State
Each TerminalPanel has independent isTextBoxActive, textBoxContent, and
inputTextView reference. Switching tabs preserves TextBox state.

## Settings (Settings > TextBox Input)

- **Enable Mode**: Toggle TextBox on/off (default: off)
- **Send on Return**: On = Return sends / Shift+Enter inserts newline,
  Off = Enter inserts newline / Shift+Enter sends (default: on)
- **Escape Key**: Send ESC Key or Focus Terminal (default: Send ESC Key)
- **Keyboard Shortcut (Cmd+Option+B)**: Toggle Display or Toggle Focus
  (default: Toggle Focus). Key is customizable in Keyboard Shortcuts settings.

## Test Plan

### T1. Settings
- [ ] T1.1  Default values: enabled=false, enterToSend=true, escape=sendEscape, shortcut=toggleFocus
- [ ] T1.2  Toggle each setting and verify it persists across app restart
- [ ] T1.3  Reset All restores all settings to defaults
- [ ] T1.4  Settings rows are dimmed/disabled when Enable Mode is off

### T2. Basic Text Editing (F1)
- [ ] T2.1  Type text and verify it appears in the TextBox
- [ ] T2.2  Cmd+A selects all text
- [ ] T2.3  Cmd+C/V/X copy, paste, cut
- [ ] T2.4  Cmd+Z undo, Shift+Cmd+Z redo
- [ ] T2.5  Option+Left/Right moves by word
- [ ] T2.6  Mouse click positions cursor
- [ ] T2.7  Mouse drag selects text
- [ ] T2.8  Double-click selects word, triple-click selects line

### T3. IME (F2)
- [ ] T3.1  Japanese input (Hiragana → Kanji conversion) completes correctly
- [ ] T3.2  Chinese pinyin input works
- [ ] T3.3  Korean input works
- [ ] T3.4  IME composition is not interrupted by terminal title updates

### T4. Multi-line & Auto-grow (F3, F4)
- [ ] T4.1  Shift+Return inserts newline (enterToSend=on)
- [ ] T4.2  Return inserts newline (enterToSend=off)
- [ ] T4.3  TextBox height grows from 2 lines up to 8 lines
- [ ] T4.4  Beyond 8 lines, content scrolls internally
- [ ] T4.5  After submit, TextBox shrinks back to minimum height

### T5. Key Routing — Emacs (F5, Rule 1)
- [ ] T5.1  Ctrl+A moves to beginning of line
- [ ] T5.2  Ctrl+E moves to end of line
- [ ] T5.3  Ctrl+F moves forward, Ctrl+B moves backward
- [ ] T5.4  Ctrl+N moves down, Ctrl+P moves up (multi-line)
- [ ] T5.5  Ctrl+K kills to end of line
- [ ] T5.6  Ctrl+H deletes backward

### T6. Key Routing — Terminal Forwarding (F5, Rules 2–5, 9)
- [ ] T6.1  Ctrl+C sends SIGINT to terminal (focus stays in TextBox)
- [ ] T6.2  Ctrl+D sends EOF to terminal
- [ ] T6.3  Ctrl+Z sends SIGTSTP to terminal
- [ ] T6.4  Ctrl+L clears terminal screen
- [ ] T6.5  "/" in empty TextBox + Claude Code → forwarded, focus moves to terminal
- [ ] T6.6  "/" in non-empty TextBox → typed as text
- [ ] T6.7  "/" in empty TextBox + plain shell → typed as text
- [ ] T6.8  "@" in empty TextBox + Claude Code → forwarded, focus moves to terminal
- [ ] T6.9  "@" in empty TextBox + Codex → forwarded, focus moves to terminal
- [ ] T6.10 "?" in empty TextBox + Claude Code → forwarded as key event, focus stays
- [ ] T6.11 "?" in non-empty TextBox → typed as text
- [ ] T6.12 Arrow Up/Down in empty TextBox → shell history navigation
- [ ] T6.13 Tab in empty TextBox → tab completion in terminal
- [ ] T6.14 Backspace in empty TextBox → forwarded to terminal
- [ ] T6.15 Arrow keys in non-empty TextBox → cursor movement within TextBox

### T7. Submit & Escape (F5, Rules 6–8)
- [ ] T7.1  Return submits text (enterToSend=on)
- [ ] T7.2  Shift+Return submits text (enterToSend=off)
- [ ] T7.3  Submitted text appears in terminal with command execution
- [ ] T7.4  TextBox is cleared after submit
- [ ] T7.5  Empty submit sends just Return to terminal
- [ ] T7.6  Escape sends ESC key to terminal (escape=sendEscape)
- [ ] T7.7  Escape moves focus to terminal (escape=focusTerminal)
- [ ] T7.8  Multi-line text is sent correctly via bracket paste

### T8. Theme Sync (F6)
- [ ] T8.1  TextBox background matches terminal background color
- [ ] T8.2  TextBox text color matches terminal foreground color
- [ ] T8.3  TextBox respects background-opacity setting
- [ ] T8.4  Selection color is inverted (fg on bg)
- [ ] T8.5  Font size matches terminal font size
- [ ] T8.6  Cursor (insertion point) color matches foreground
- [ ] T8.7  Theme changes are reflected immediately

### T9. Toggle Shortcut (F7)
- [ ] T9.1  Cmd+Opt+B shows TextBox when hidden (toggleDisplay mode)
- [ ] T9.2  Cmd+Opt+B hides TextBox when shown (toggleDisplay mode)
- [ ] T9.3  Cmd+Opt+B moves focus to TextBox when unfocused (toggleFocus mode)
- [ ] T9.4  Cmd+Opt+B moves focus to terminal when TextBox focused (toggleFocus mode)
- [ ] T9.5  Toggle applies to all tabs simultaneously
- [ ] T9.6  Custom shortcut key works after changing in Settings
- [ ] T9.7  Enabling "Enable Mode" setting forces TextBox visible

### T10. Drag & Drop (F8)
- [ ] T10.1  Drop single file → shell-escaped path inserted
- [ ] T10.2  Drop multiple files → space-separated escaped paths
- [ ] T10.3  Drop folder → folder path inserted
- [ ] T10.4  Paths with spaces/special chars are properly escaped
- [ ] T10.5  Green "+" badge appears when dragging over TextBox
- [ ] T10.6  Dropped text is selected for review
- [ ] T10.7  Drop onto terminal area still works normally

### T11. Focus Guards (F11)
- [ ] T11.1  Terminal ensureFocus does not steal focus from TextBox
- [ ] T11.2  Find panel close does not steal focus from TextBox
- [ ] T11.3  Clicking TextBox gives it focus
- [ ] T11.4  Border brightens when focused, dims when unfocused

### T12. App Detection (F12)
- [ ] T12.1  "Claude Code" in title → detected
- [ ] T12.2  "✱ Claude Code" or "✳ Claude Code" (with icon) → detected
- [ ] T12.2b Title starting with "✳" (e.g. "✳ Japanese greeting conversation") → detected as Claude Code
- [ ] T12.2c Title starting with "⠂" (e.g. "⠂ New coding session") → detected as Claude Code
- [ ] T12.3  "Codex" in title → detected
- [ ] T12.4  "zsh" or "bash" → not detected
- [ ] T12.5  Detection is case-insensitive

### T13. Bracket Paste & Timing (F13)
- [ ] T13.1  Pasted text arrives in terminal correctly
- [ ] T13.2  Return is sent after 200ms delay (not inside bracket paste)
- [ ] T13.3  Shell (zsh) executes pasted commands correctly
- [ ] T13.4  Claude CLI receives pasted prompts correctly

### T14. Per-panel State (F14)
- [ ] T14.1  Switching tabs preserves TextBox content
- [ ] T14.2  Toggle applies to all tabs simultaneously (global, not per-tab)
- [ ] T14.3  New tab inherits global Enable Mode setting
- [ ] T14.4  Split panes each have their own TextBox

### T15. Placeholder & Send Button (F9, F10)
- [ ] T15.1  Placeholder text shows when TextBox is empty
- [ ] T15.2  Placeholder disappears when text is entered
- [ ] T15.3  Placeholder reflects current send key setting
- [ ] T15.4  Send button submits text on click
- [ ] T15.5  Send button shows hover highlight
- [ ] T15.6  Send button shows press state

## Upstream Impact

Code added to upstream (manaflow-ai/cmux) files is marked with `[TextBox]`.
Run `grep -r '\[TextBox\]' Sources/` to list all locations.
*/

import AppKit
import SwiftUI

// MARK: - Constants

/// Layout constants for the TextBox bar (outer container with padding, button, spacing).
private enum TextBoxLayout {
    /// Font size of the send button icon.
    static let sendButtonSize: CGFloat = 18
    /// Spacing between the text view and the send button.
    static let contentSpacing: CGFloat = 4
    /// Left padding of the entire TextBox bar.
    static let leftPadding: CGFloat = 8
    /// Right padding of the entire TextBox bar.
    static let rightPadding: CGFloat = 8
    /// Top padding of the entire TextBox bar.
    static let topPadding: CGFloat = 8
    /// Bottom padding of the entire TextBox bar.
    static let bottomPadding: CGFloat = 8
}

/// Layout constants for the internal NSTextView (font, sizing, border, insets).
private enum TextBoxInputViewLayout {
    /// Minimum number of visible lines.
    static let minLines: Int = 2
    /// Maximum number of visible lines before the text view starts scrolling internally.
    static let maxLines: Int = 8
    /// Added to the terminal font size for the TextBox font (slightly larger for readability).
    static let fontSizeOffset: CGFloat = 1
    /// Extra spacing between lines in multi-line input.
    static let lineSpacing: CGFloat = 4
    /// Inset between the text and the text view's border (width=horizontal, height=vertical).
    static let textInset = NSSize(width: 2, height: 6)
    /// Border stroke width around the text view container.
    static let borderWidth: CGFloat = 1
    /// Border color opacity when unfocused (fraction of the terminal foreground color).
    static let borderOpacity: CGFloat = 0.25
    /// Border color opacity when focused (caret is in the text view).
    static let focusedBorderOpacity: CGFloat = 0.45
    /// Corner radius of the text view container.
    static let cornerRadius: CGFloat = 6
    /// Opacity of the placeholder text (fraction of the terminal foreground color).
    static let placeholderOpacity: CGFloat = 0.35
    /// Placeholder text shown when the TextBox is empty.
    /// The send key name changes based on the Enter-to-Send setting.
    static func placeholderText(enterToSend: Bool) -> String {
        if enterToSend {
            return String(localized: "textbox.placeholder.enterToSend", defaultValue: "Commands or prompts here… Shift+Return for newline")
        } else {
            return String(localized: "textbox.placeholder.enterToNewline", defaultValue: "Commands or prompts here… Shift+Return to send")
        }
    }
}

/// Behavioral constants for TextBox (timing, thresholds, etc.).
private enum TextBoxBehavior {
    /// Delay (ms) between sending pasted text and the Return key.
    /// Apps using bracket paste mode (zsh, Claude CLI) need time to process
    /// the paste before receiving Return. 50ms/100ms are insufficient;
    /// 200ms is the minimum reliable value. See `TextBoxSubmit` for details.
    /// Set to 0 to send Return immediately after the paste.
    static let returnKeyDelayMs: Int = 200
    /// Delay (ms) before sending Return when the TextBox is empty (no paste).
    /// Set to 0 to send Return immediately (default).
    static let emptyReturnKeyDelayMs: Int = 0
    /// Scope of the Cmd+Opt+B toggle shortcut.
    /// `.active` = only the focused tab, `.all` = all tabs simultaneously.
    static let toggleScope: TextBoxToggleTarget = .all
}

// MARK: - Toggle Scope

/// Scope of the TextBox toggle shortcut (Cmd+Opt+B).
enum TextBoxToggleTarget {
    /// Toggle only the currently active (focused or TextBox-focused) panel.
    case active
    /// Toggle all terminal panels simultaneously.
    case all

    /// The configured default scope, read from TextBoxBehavior.
    static var `default`: TextBoxToggleTarget { TextBoxBehavior.toggleScope }
}

// MARK: - App Detection

/// Terminal apps detected by tab title for key routing decisions.
/// Used by `TextBoxKeyRouting` to determine which prefixes to forward.
enum TextBoxAppDetection: CaseIterable {
    case claudeCode
    case codex

    /// Regex pattern matched (case-insensitive) against the terminal tab title.
    /// Claude Code detection: matches "Claude Code" anywhere in the title,
    /// or a title starting with "✱ " / "✳ " (idle/active icon) or "⠂ " (thinking indicator).
    private var tabTitlePattern: String {
        switch self {
        case .claudeCode: return "Claude Code|^[✱✳⠂] "
        case .codex:      return "Codex"
        }
    }

    /// Returns true if the terminal tab title indicates this app is running.
    func matches(terminalTitle: String) -> Bool {
        terminalTitle.range(
            of: tabTitlePattern,
            options: [.caseInsensitive, .regularExpression]
        ) != nil
    }
}

// MARK: - Focus State

/// The three observable states of the TextBox, used to decide what the
/// toggle shortcut (Cmd+Opt+B) should do.
///
/// Transitions on shortcut press:
///   hidden           → show TextBox + focus it
///   visibleUnfocused → focus TextBox (don't hide it)
///   visibleFocused   → hide TextBox + focus terminal
enum TextBoxFocusState {
    /// TextBox is not displayed.
    case hidden
    /// TextBox is displayed but the terminal (or another view) has focus.
    case visibleUnfocused
    /// TextBox is displayed and has keyboard focus.
    case visibleFocused

    /// Determine the current state from panel and window state.
    static func current(isTextBoxActive: Bool, window: NSWindow?) -> TextBoxFocusState {
        guard isTextBoxActive else { return .hidden }
        guard let firstResponder = window?.firstResponder else { return .visibleUnfocused }
        if firstResponder is InputTextView {
            return .visibleFocused
        }
        return .visibleUnfocused
    }

}

// MARK: - Key Routing
//
// All TextBox key handling is governed by the rule table below.
// Rules are evaluated top-down; the first match wins. Unmatched
// keys fall through to default TextBox text input.
//
// Rules are evaluated within each input path (keyDown / insertText /
// doCommand). Groups never overlap because each NSTextView interception
// point produces a distinct input type.
//
// | # | Modifier | Key              | TextBox | App              | Action                                |
// |---|----------|------------------|---------|------------------|---------------------------------------|
// | 1  | Ctrl     | A E F B N P K H  | any     | any              | Emacs editing (handled by NSTextView) |
// | 2  | Ctrl     | * (other)        | any     | any              | Forward to terminal (keep focus)      |
// | 3  |          | /                | empty   | claudeCode,codex | Forward prefix + focus terminal       |
// | 4  |          | @                | empty   | claudeCode,codex | Forward prefix + focus terminal       |
// | 5  |          | ?                | empty   | claudeCode,codex | Forward key event to terminal (keep focus) |
// | 6  |          | Return           | any     | any              | Submit or newline (setting)           |
// | 7  | Shift    | Return           | any     | any              | Newline or submit (inverse of 6)      |
// | 8  |          | Escape           | any     | any              | Focus terminal or send ESC (setting)  |
// | 9  |          | ↑ ↓ ← → Tab BS   | empty   | any              | Forward key to terminal (keep focus)  |
// | 10 | *        | *                | any     | any              | TextBox text input (fallback)         |

/// Normalized input from the three NSTextView interception points.
enum TextBoxKeyInput {
    /// From keyDown(): Ctrl + character key.
    case ctrl(String)
    /// From keyDown(): unmodified character key (no Ctrl/Cmd/Option).
    case key(String)
    /// From insertText(): committed text character.
    case text(String)
    /// From doCommand(): AppKit-interpreted command selector.
    case command(Selector, shifted: Bool)
}

/// Routing result — tells the caller what action to take.
enum TextBoxKeyAction {
    /// Rule 1: Pass to NSTextView for Emacs-style editing.
    case emacsEdit
    /// Rule 2: Forward raw Ctrl+key event to terminal (keep focus).
    case forwardControl
    /// Rule 3/4: Forward prefix character to terminal and move focus.
    case forwardPrefix(String)
    /// Rule 5: Forward raw key event to terminal (keep focus).
    case forwardKeyEvent
    /// Rule 6/7: Send TextBox content to terminal.
    case submit
    /// Rule 6/7: Insert newline into TextBox.
    case insertNewline
    /// Rule 8: Escape action (setting-dependent).
    case escape
    /// Rule 9: Forward interpreted key to terminal (keep focus).
    case forwardKey(TextBoxKeyRouting.TerminalKey)
    /// Fallback: Default TextBox text input.
    case textInput
}

/// Centralized key routing for TextBox. All routing decisions are made here;
/// each NSTextView interception point (`keyDown`, `insertText`, `doCommand`)
/// converts its input to `TextBoxKeyInput` and calls `route()`.
///
/// All key definitions are collected in this enum so new rules can be added
/// in one place without touching the interception points.
enum TextBoxKeyRouting {

    // MARK: Key Definitions

    /// Named keys that TextBox forwards to the terminal via synthetic NSEvents.
    enum TerminalKey {
        case returnKey, arrowUp, arrowDown, arrowLeft, arrowRight, tab, backspace, escape

        var characters: String {
            switch self {
            case .returnKey: return "\r"
            case .arrowUp:   return "\u{F700}"
            case .arrowDown: return "\u{F701}"
            case .arrowLeft: return "\u{F702}"
            case .arrowRight: return "\u{F703}"
            case .tab:       return "\t"
            case .backspace: return "\u{7F}"
            case .escape:    return "\u{1B}"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .returnKey: return 36
            case .arrowUp:   return 126
            case .arrowDown: return 125
            case .arrowLeft: return 123
            case .arrowRight: return 124
            case .tab:       return 48
            case .backspace: return 51
            case .escape:    return 53
            }
        }
    }

    /// Rule 1: Emacs editing keys — Ctrl+key handled locally by NSTextView.
    private static let emacsEditingKeys: Set<String> = [
        "a",  // moveToBeginningOfLine:
        "e",  // moveToEndOfLine:
        "f",  // moveForward:
        "b",  // moveBackward:
        "n",  // moveDown:
        "p",  // moveUp:
        "k",  // deleteToEndOfLine: (via killLine:)
        "h",  // deleteBackward:
    ]

    /// Rules 3, 4: Prefixes forwarded to terminal when TextBox is empty (+ focus terminal).
    private static let prefixForwardKeys: [TextBoxAppDetection: [String]] = [
        .claudeCode: ["/", "@"],
        .codex:      ["/", "@"],
    ]

    /// Rule 5: Text forwarded to terminal when TextBox is empty (keep focus).
    private static let textForwardKeys: [TextBoxAppDetection: [String]] = [
        .claudeCode: ["?"],
        .codex:      ["?"],
    ]

    /// Rule 7: Selectors forwarded to terminal when TextBox is empty.
    private static let emptyStateSelectors: [Selector: TerminalKey] = [
        #selector(NSResponder.moveUp(_:)):         .arrowUp,
        #selector(NSResponder.moveDown(_:)):       .arrowDown,
        #selector(NSResponder.moveLeft(_:)):       .arrowLeft,
        #selector(NSResponder.moveRight(_:)):      .arrowRight,
        #selector(NSResponder.insertTab(_:)):      .tab,
        #selector(NSResponder.deleteBackward(_:)): .backspace,
    ]

    // MARK: Routing

    /// Single entry point for all key routing decisions.
    static func route(
        _ input: TextBoxKeyInput,
        isEmpty: Bool,
        terminalTitle: String,
        enterToSend: Bool
    ) -> TextBoxKeyAction {
        switch input {

        // Rules 1, 2: Ctrl+key
        case .ctrl(let char):
            if emacsEditingKeys.contains(char) { return .emacsEdit }      // Rule 1
            return .forwardControl                                        // Rule 2

        // Rule 5: Unmodified key forwarded as raw event (keep focus)
        case .key(let char):
            if isEmpty {
                for (app, keys) in textForwardKeys
                    where keys.contains(char) && app.matches(terminalTitle: terminalTitle) {
                    return .forwardKeyEvent                               // Rule 5
                }
            }
            return .textInput                                             // Rule 10 (Fallback)

        // Rules 3, 4, fallback: Inserted text
        case .text(let str):
            if isEmpty {
                for (app, keys) in prefixForwardKeys
                    where keys.contains(str) && app.matches(terminalTitle: terminalTitle) {
                    return .forwardPrefix(str)                            // Rule 3, 4
                }
            }
            return .textInput                                             // Rule 10 (Fallback)

        // Rules 6, 7, 8, 9: Command selectors
        case .command(let selector, let shifted):
            // Rule 6, 7: Return
            if selector == #selector(NSResponder.insertNewline(_:)) ||
               selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                let shouldSend = enterToSend ? !shifted : shifted
                return shouldSend ? .submit : .insertNewline
            }
            // Rule 8: Escape
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                return .escape
            }
            // Rule 9: Empty-state navigation
            if isEmpty, let key = emptyStateSelectors[selector] {
                return .forwardKey(key)
            }
            return .textInput                                             // Rule 10 (Fallback)
        }
    }
}

// MARK: - Key Events

/// Events dispatched from the TextBox to its parent for terminal forwarding.
enum TextBoxKeyEvent {
    /// User pressed Return/Shift+Return to submit text.
    case submit
    /// User pressed Escape.
    case escape
    /// A named key to forward to the terminal (arrows, Tab, Backspace).
    case key(TextBoxKeyRouting.TerminalKey)
    /// A Ctrl+key combination to forward as a raw NSEvent.
    case control(NSEvent)
}

// MARK: - Settings

/// Settings for TextBox Input Mode
enum TextBoxInputSettings {
    static let enabledKey = "textBoxEnabled"
    static let enterToSendKey = "textBoxEnterToSend"
    static let escapeBehaviorKey = "textBoxEscapeBehavior"
    static let shortcutBehaviorKey = "textBoxShortcutBehavior"

    static let defaultEnabled = false
    static let defaultEnterToSend = true
    static let defaultEscapeBehavior = TextBoxEscapeBehavior.sendEscape
    static let defaultShortcutBehavior = TextBoxShortcutBehavior.toggleFocus

    /// Opacity applied to settings rows when TextBox is disabled.
    static let disabledSettingsOpacity: Double = 0.5

    /// Reset all TextBox settings to defaults via UserDefaults.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: enterToSendKey)
        UserDefaults.standard.removeObject(forKey: escapeBehaviorKey)
        UserDefaults.standard.removeObject(forKey: shortcutBehaviorKey)
    }

    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    static func isEnabled() -> Bool {
        bool(forKey: enabledKey, default: defaultEnabled)
    }

    static func isEnterToSend() -> Bool {
        bool(forKey: enterToSendKey, default: defaultEnterToSend)
    }

    static func escapeBehavior() -> TextBoxEscapeBehavior {
        guard let raw = UserDefaults.standard.string(forKey: escapeBehaviorKey),
              let value = TextBoxEscapeBehavior(rawValue: raw) else {
            return defaultEscapeBehavior
        }
        return value
    }

    static func shortcutBehavior() -> TextBoxShortcutBehavior {
        guard let raw = UserDefaults.standard.string(forKey: shortcutBehaviorKey),
              let value = TextBoxShortcutBehavior(rawValue: raw) else {
            return defaultShortcutBehavior
        }
        return value
    }
}

/// What the keyboard shortcut (Cmd+Opt+B) does.
enum TextBoxShortcutBehavior: String, CaseIterable, Identifiable {
    /// Toggle TextBox visibility (show/hide).
    case toggleDisplay = "toggleDisplay"
    /// Keep TextBox always visible, toggle focus between TextBox and terminal.
    case toggleFocus = "toggleFocus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleDisplay:
            return String(localized: "textbox.shortcutBehavior.toggleDisplay", defaultValue: "Toggle Display")
        case .toggleFocus:
            return String(localized: "textbox.shortcutBehavior.toggleFocus", defaultValue: "Toggle Focus")
        }
    }
}

/// What happens when the user presses Escape in the TextBox.
enum TextBoxEscapeBehavior: String, CaseIterable, Identifiable {
    /// Send the ESC key to the terminal and keep focus in the TextBox.
    case sendEscape = "sendEscape"
    /// Move focus back to the terminal without sending ESC.
    case focusTerminal = "focusTerminal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sendEscape:
            return String(localized: "textbox.escapeBehavior.sendEscape", defaultValue: "Send ESC Key")
        case .focusTerminal:
            return String(localized: "textbox.escapeBehavior.focusTerminal", defaultValue: "Focus Terminal")
        }
    }
}

// MARK: - Text Submission

/// Send text through TextBox: writes to PTY via bracket paste, then
/// sends Return as a separate synthetic key event after a delay.
///
/// **Why not `sendText(text + "\r")` or `sendText(text + "\n")`?**
/// `sendText` wraps content in bracket paste (`\x1b[200~…\x1b[201~`).
/// Applications that enable bracket paste mode (zsh, Claude CLI, etc.)
/// treat `\r`/`\n` inside the paste as literal characters, not as
/// command execution. Return must be sent as a separate synthetic key
/// event *outside* the paste sequence.
/// Note: `sendText(text + "\n")` does work for apps that don't use
/// bracket paste (e.g., node REPL), but fails for shell and Claude CLI.
///
/// **Why 200ms delay?**
/// Claude CLI shows "pasting text…" while processing bracket paste
/// (~100ms). If Return arrives before processing finishes, it is
/// silently ignored. 50ms and 100ms were tested and are insufficient.
/// 200ms is the minimum reliable value.
enum TextBoxSubmit {
    static func send(_ text: String, via surface: TerminalSurface) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let delayMs = TextBoxBehavior.returnKeyDelayMs
        if !trimmed.isEmpty {
            surface.sendText(trimmed)
        }
        let effectiveDelayMs = trimmed.isEmpty
            ? TextBoxBehavior.emptyReturnKeyDelayMs
            : delayMs
        if effectiveDelayMs <= 0 {
            surface.sendKey(.returnKey)
        } else {
            let delay = TimeInterval(effectiveDelayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak surface] in
                surface?.sendKey(.returnKey)
            }
        }
    }
}

// MARK: - Container View

/// Inline text input that sits flush at the bottom of the terminal.
///
/// Styled as a thin single-line field with the terminal's own colors so it looks
/// like the prompt's caret area was replaced by a native text field.
///
/// Accepts a `TerminalSurface` directly so that all key forwarding and
/// text submission logic stays inside TextBoxInput.swift, minimizing
/// TextBox-specific code in upstream files.
struct TextBoxInputContainer: View {
    @Binding var text: String
    let enterToSend: Bool
    let surface: TerminalSurface
    let terminalBackgroundColor: NSColor
    let terminalForegroundColor: NSColor
    let terminalFont: NSFont
    let terminalTitle: String
    /// Called when the InputTextView is created, so the panel can store a direct
    /// reference for focus management across multiple tabs.
    let onInputTextViewCreated: ((InputTextView) -> Void)?
    @State private var textViewHeight: CGFloat = 0

    /// Computes the height for a given number of lines using the current font.
    private func heightForLines(_ count: Int) -> CGFloat {
        let fontSize = max(1, terminalFont.pointSize + TextBoxInputViewLayout.fontSizeOffset)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = font.ascender - font.descender + font.leading
            + TextBoxInputViewLayout.lineSpacing
        return lineHeight * CGFloat(count) + TextBoxInputViewLayout.textInset.height * 2
    }

    var body: some View {
        let minH = heightForLines(TextBoxInputViewLayout.minLines)
        let maxH = heightForLines(TextBoxInputViewLayout.maxLines)
        let clampedHeight = max(minH, min(maxH, textViewHeight))

        HStack(alignment: .bottom, spacing: TextBoxLayout.contentSpacing) {
            TextBoxInputView(
                text: $text,
                enterToSend: enterToSend,
                textViewHeight: $textViewHeight,
                onKeyEvent: { event in
                    switch event {
                    case .submit:
                        submit()
                    case .escape:
                        switch TextBoxInputSettings.escapeBehavior() {
                        case .focusTerminal:
                            surface.focusTerminalView()
                        case .sendEscape:
                            surface.sendKey(.escape)
                        }
                    case .key(let key):
                        surface.sendKey(key)
                    case .control(let nsEvent):
                        surface.forwardKeyEvent(nsEvent)
                    }
                },
                onPrefixForward: { prefix in
                    surface.sendText(prefix)
                    surface.focusTerminalView()
                },
                onInputTextViewCreated: onInputTextViewCreated,
                terminalBackgroundColor: terminalBackgroundColor,
                terminalForegroundColor: terminalForegroundColor,
                terminalFont: terminalFont,
                terminalTitle: terminalTitle
            )
            .frame(height: clampedHeight)

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: TextBoxLayout.sendButtonSize))
            }
            .buttonStyle(TextBoxSendButtonStyle(foregroundColor: Color(nsColor: terminalForegroundColor)))
            .help(String(localized: "textbox.send.tooltip", defaultValue: "Send"))
        }
        .padding(.leading, TextBoxLayout.leftPadding)
        .padding(.trailing, TextBoxLayout.rightPadding)
        .padding(.top, TextBoxLayout.topPadding)
        .padding(.bottom, TextBoxLayout.bottomPadding)
        .background(Color(nsColor: terminalBackgroundColor))
        // [TextBox] Restore terminal scroll position after TextBox height changes.
        // When the VStack resizes the terminal, ghostty sends SIGWINCH which causes
        // TUI apps like Claude Code to re-render and snap to the bottom. We save the
        // scroll offset before the resize and restore it after a short delay.
        .onChange(of: clampedHeight) { [clampedHeight] _ in
            guard clampedHeight > 0 else { return }
            guard surface.isScrolledUp,
                  let savedOffset = surface.scrollbarOffset else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                surface.scrollToRow(savedOffset)
            }
        }
    }

    private func submit() {
        let content = text
        TextBoxSubmit.send(content, via: surface)
        text = ""
        // Reset height to minimum so the TextBox shrinks after sending
        // multi-line content. The binding update (text = "") triggers
        // updateNSView which calls recalcHeight, but the layout pass
        // may not run soon enough for the frame to shrink visually.
        textViewHeight = 0
    }
}

// MARK: - NSViewRepresentable

/// NSViewRepresentable that wraps NSTextView for inline terminal input.
///
/// Styled to blend with the terminal: same background/foreground colors, monospace font,
/// with a subtle border to indicate it is a native editable field.
struct TextBoxInputView: NSViewRepresentable {
    @Binding var text: String
    let enterToSend: Bool
    @Binding var textViewHeight: CGFloat
    let onKeyEvent: (TextBoxKeyEvent) -> Void
    let onPrefixForward: (String) -> Void
    let onInputTextViewCreated: ((InputTextView) -> Void)?
    let terminalBackgroundColor: NSColor
    let terminalForegroundColor: NSColor
    let terminalFont: NSFont
    let terminalTitle: String

    private var adjustedFont: NSFont {
        let size = max(1, terminalFont.pointSize + TextBoxInputViewLayout.fontSizeOffset)
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func makeParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TextBoxInputViewLayout.lineSpacing
        return style
    }

    private func makeTypingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: adjustedFont,
            .foregroundColor: terminalForegroundColor,
            .paragraphStyle: makeParagraphStyle(),
        ]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        // Border is on a container NSView, not on the NSScrollView directly.
        // Setting `wantsLayer = true` + `layer?.borderWidth` on NSScrollView
        // does not render a border (its layer management conflicts with
        // direct layer property access). A plain NSView wrapper works reliably.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderWidth = TextBoxInputViewLayout.borderWidth
        container.layer?.borderColor = terminalForegroundColor.withAlphaComponent(TextBoxInputViewLayout.borderOpacity).cgColor
        container.layer?.cornerRadius = TextBoxInputViewLayout.cornerRadius
        container.layer?.masksToBounds = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = InputTextView()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindPanel = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Ensure the text view resizes horizontally with the scroll view's
        // content area. Without this, the text container width may stay at 0
        // on macOS Sonoma/Sequoia, making typed text invisible. (#6)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = TextBoxInputViewLayout.textInset
        textView.delegate = context.coordinator
        textView.inputCoordinator = context.coordinator
        textView.enterToSend = enterToSend

        // Match terminal appearance — background is drawn by the outer
        // SwiftUI .background() to avoid double-compositing when the
        // terminal uses background-opacity < 1.
        textView.drawsBackground = false
        textView.insertionPointColor = terminalForegroundColor
        textView.textColor = terminalForegroundColor
        // Match terminal selection colors: foreground on background inverted.
        textView.selectedTextAttributes = [
            .backgroundColor: terminalForegroundColor,
            .foregroundColor: terminalBackgroundColor.withAlphaComponent(1.0),
        ]
        textView.font = adjustedFont
        textView.typingAttributes = makeTypingAttributes()
        textView.defaultParagraphStyle = makeParagraphStyle()

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.container = container

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Register this InputTextView with the panel for direct focus management
        onInputTextViewCreated?(textView)

        // Auto-focus the text view and calculate initial height.
        // Only auto-focus if nothing else currently has focus (i.e. the
        // window has no first responder yet). When toggling all tabs at once,
        // the active tab's terminal already has focus and must not be stolen.
        DispatchQueue.main.async {
            if textView.window?.firstResponder == textView.window {
                textView.window?.makeFirstResponder(textView)
            }
            context.coordinator.recalcHeight(textView)
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let scrollView = container.subviews.first as? NSScrollView,
              let textView = scrollView.documentView as? InputTextView else { return }
        context.coordinator.parent = self
        // Skip text sync during IME composition: textView.string includes marked
        // (uncommitted) text while the binding only has committed text. Overwriting
        // here would disrupt the active input method session.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight(textView)
        }
        // Keep enterToSend, colors, and terminal title in sync
        textView.enterToSend = enterToSend
        textView.terminalTitle = terminalTitle
        textView.insertionPointColor = terminalForegroundColor
        textView.textColor = terminalForegroundColor
        textView.selectedTextAttributes = [
            .backgroundColor: terminalForegroundColor,
            .foregroundColor: terminalBackgroundColor.withAlphaComponent(1.0),
        ]
        textView.typingAttributes = makeTypingAttributes()
        let isFocused = textView.window?.firstResponder === textView
        let opacity = isFocused
            ? TextBoxInputViewLayout.focusedBorderOpacity
            : TextBoxInputViewLayout.borderOpacity
        container.layer?.borderColor = terminalForegroundColor.withAlphaComponent(opacity).cgColor
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxInputView
        weak var textView: NSTextView?
        weak var container: NSView?

        init(_ parent: TextBoxInputView) {
            self.parent = parent
        }

        func updateBorderOpacity(focused: Bool) {
            let opacity = focused
                ? TextBoxInputViewLayout.focusedBorderOpacity
                : TextBoxInputViewLayout.borderOpacity
            container?.layer?.borderColor = parent.terminalForegroundColor
                .withAlphaComponent(opacity).cgColor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalcHeight(textView)
        }

        func recalcHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            parent.textViewHeight = contentHeight
        }

    }
}

// MARK: - Send Button Style

/// Button style with hover/press highlight for the TextBox send button.
private struct TextBoxSendButtonStyle: ButtonStyle {
    let foregroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        TextBoxSendButtonBody(configuration: configuration, foregroundColor: foregroundColor)
    }
}

private struct TextBoxSendButtonBody: View {
    let configuration: TextBoxSendButtonStyle.Configuration
    let foregroundColor: Color
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .foregroundColor(foregroundColor)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(foregroundColor.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - InputTextView

/// Custom NSTextView subclass that routes key events to the coordinator.
///
/// Two separate interception layers are used intentionally:
///
/// 1. **`keyDown`** — intercepts Ctrl+key *before* AppKit interprets them.
///    Ctrl+C, Ctrl+D, etc. must always reach the terminal regardless of
///    TextBox content. If we waited for `doCommandBySelector`, AppKit
///    would convert them into selectors and they wouldn't reach the
///    terminal correctly.
///
/// 2. **`doCommandBySelector`** — handles interpreted commands (arrows,
///    Tab, Backspace, Enter, Escape). These are forwarded to the terminal
///    only when the TextBox is empty (except Enter/Escape which are always
///    handled). Using `doCommandBySelector` instead of raw `keyDown`
///    forwarding avoids `^^` garbage characters that appear when
///    forwarding raw NSEvents.
final class InputTextView: NSTextView {
    weak var inputCoordinator: TextBoxInputView.Coordinator?
    var enterToSend: Bool = false
    /// Current terminal process title, used for app detection in key routing.
    var terminalTitle: String = ""

    /// Set by keyDown when a key event was already forwarded to the terminal,
    /// so insertText can skip the duplicate insertion that the input method
    /// system triggers in parallel.
    private var keyEventAlreadyForwarded = false

    // Shell-escape characters matching terminal drag-and-drop behavior.
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    private static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Insert shell-escaped file paths, focus the TextBox, and select the
    /// inserted text. Called from FileDropOverlayView when a Finder file drag
    /// is dropped over the TextBox area.
    ///
    /// Uses asyncAfter(0.05s) because the drop is routed through
    /// FileDropOverlayView's performDragOperation, and synchronous text
    /// insertion during a drag session stalls until the next mouse event.
    func insertDroppedFilePaths(_ urls: [URL]) {
        let escaped = urls
            .map { Self.escapeForShell($0.path) }
            .joined(separator: " ")

        let capturedWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let range = capturedWindow?.firstResponder === self
                ? self.selectedRange()
                : NSRange(location: self.string.count, length: 0)
            let insertionPoint = range.location
            capturedWindow?.makeFirstResponder(self)
            self.insertText(escaped, replacementRange: range)
            self.setSelectedRange(NSRange(location: insertionPoint, length: (escaped as NSString).length))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let placeholder = TextBoxInputViewLayout.placeholderText(enterToSend: enterToSend)
            let color = (insertionPointColor ?? .white)
                .withAlphaComponent(TextBoxInputViewLayout.placeholderOpacity)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: color,
            ]
            let inset = textContainerInset
            let origin = NSPoint(
                x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: inset.height
            )
            NSString(string: placeholder).draw(at: origin, withAttributes: attrs)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { inputCoordinator?.updateBorderOpacity(focused: true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { inputCoordinator?.updateBorderOpacity(focused: false) }
        return result
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // If keyDown already forwarded this key event to the terminal,
        // skip the text insertion that the input method system triggers.
        if keyEventAlreadyForwarded {
            keyEventAlreadyForwarded = false
            return
        }
        if let str = string as? String {
            let action = TextBoxKeyRouting.route(
                .text(str), isEmpty: self.string.isEmpty,
                terminalTitle: terminalTitle, enterToSend: enterToSend)
            switch action {
            case .forwardPrefix(let prefix):
                inputCoordinator?.parent.onPrefixForward(prefix)
                return
            case .textInput:
                break  // fall through to super
            default:
                break
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           let chars = event.charactersIgnoringModifiers {
            let action = TextBoxKeyRouting.route(
                .ctrl(chars), isEmpty: string.isEmpty,
                terminalTitle: terminalTitle, enterToSend: enterToSend)
            switch action {
            case .emacsEdit:
                super.keyDown(with: event)
            case .forwardControl:
                inputCoordinator?.parent.onKeyEvent(.control(event))
            default:
                break
            }
            return
        }

        // Rule 5: Check for unmodified keys that should be forwarded as raw events.
        // Use `characters` (not `charactersIgnoringModifiers`) because "?" is
        // Shift+"/" and we need the actual typed character.
        if let chars = event.characters {
            let action = TextBoxKeyRouting.route(
                .key(chars), isEmpty: string.isEmpty,
                terminalTitle: terminalTitle, enterToSend: enterToSend)
            if case .forwardKeyEvent = action {
                keyEventAlreadyForwarded = true
                inputCoordinator?.parent.onKeyEvent(.control(event))
                return
            }
        }

        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        let action = TextBoxKeyRouting.route(
            .command(selector, shifted: shifted), isEmpty: string.isEmpty,
            terminalTitle: terminalTitle, enterToSend: enterToSend)
        switch action {
        case .submit:
            inputCoordinator?.parent.onKeyEvent(.submit)
        case .insertNewline:
            insertNewlineIgnoringFieldEditor(nil)
        case .escape:
            inputCoordinator?.parent.onKeyEvent(.escape)
        case .forwardKey(let key):
            inputCoordinator?.parent.onKeyEvent(.key(key))
        case .textInput:
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }
}

// MARK: - Settings View Modifier

extension View {
    /// Dims and disables a settings row when TextBox is not enabled.
    func textBoxSettingsDisabled(_ isDisabled: Bool) -> some View {
        self
            .disabled(isDisabled)
            .opacity(isDisabled ? TextBoxInputSettings.disabledSettingsOpacity : 1.0)
    }
}
