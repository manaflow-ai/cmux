public import Foundation
public import Observation

/// The terminal soft-keyboard input policy, extracted from the UIKit input
/// proxy (DECOMPOSITION-PLAN §2c): owns the armed/sticky modifier state
/// machine and translates committed text, backspace, and accessory taps into
/// the VT bytes (or plain text) the host should emit.
///
/// The `UITextView` host is a dumb first responder: it forwards events here,
/// dispatches the returned ``TerminalInputEmission`` to its send closures,
/// and restyles its modifier buttons from ``isArmed(_:)`` /
/// ``isStickyOn(_:)``.
///
/// Resolutions are **returned**, not streamed: this is the per-keystroke
/// typing-latency path, and the prefer-values rule beats an `AsyncStream`
/// hop that would add a main-queue turn per keystroke. State changes are
/// observable for SwiftUI consumers via `@Observable`.
@MainActor
@Observable
public final class TerminalInputCoordinator {
    /// What an accessory-bar tap resolved to.
    public enum AccessoryResolution: Equatable, Sendable {
        /// Nothing to emit (e.g. a modifier toggled its armed state).
        case none
        /// Drive a font zoom step.
        case zoom(TerminalFontZoomDirection)
        /// Emit text/bytes to the terminal.
        case emission(TerminalInputEmission)
    }

    /// What a backspace resolved to.
    public enum BackspaceResolution: Equatable, Sendable {
        /// Send the plain DEL (0x7F) the host's default path emits.
        case plainDelete
        /// Emit a modifier-translated byte sequence instead.
        case emission(TerminalInputEmission)
        /// Consume the backspace without emitting (an armed modifier had no
        /// mapping; matches the pre-extraction early return).
        case suppressed
    }

    private var modifierState = TerminalInputModifierState()

    /// Creates a coordinator with no modifiers armed.
    public init() {}

    // MARK: - Modifier state (read by the host for button styling)

    /// Whether `modifier` is currently armed (one-shot or sticky).
    public func isArmed(_ modifier: TerminalInputModifier) -> Bool {
        modifierState.isArmed(modifier)
    }

    /// Whether `modifier` is sticky-locked (double-tapped).
    public func isStickyOn(_ modifier: TerminalInputModifier) -> Bool {
        modifierState.isStickyOn(modifier)
    }

    /// Toggles `modifier` (tap), promoting to sticky inside the double-tap
    /// window. `now` is injected for deterministic tests.
    public func tapModifier(_ modifier: TerminalInputModifier, now: TimeInterval) {
        modifierState.tap(modifier, now: now)
    }

    /// Disarms every modifier (including sticky locks).
    public func disarmAll() {
        modifierState.disarmAll()
    }

    /// Clears the double-tap promotion window (test seam, mirrors the
    /// pre-extraction reset).
    public func clearDoubleTapWindow() {
        modifierState.clearDoubleTapWindow()
    }

    // MARK: - Resolutions

    /// Resolves text committed by the soft keyboard / IME, applying (and
    /// consuming, unless sticky) the armed modifier.
    public func resolveCommittedText(_ text: String) -> TerminalInputEmission {
        if modifierState.isArmed(.control) {
            modifierState.consumeIfNotSticky(.control)
            if let sequence = Self.controlSequence(for: text) {
                return .sendBytes(sequence)
            }
            return .sendText(text)
        }
        if modifierState.isArmed(.alternate) {
            modifierState.consumeIfNotSticky(.alternate)
            if let sequence = Self.alternateSequence(for: text) {
                return .sendBytes(sequence)
            }
            return .sendText(text)
        }
        if modifierState.isArmed(.command) {
            modifierState.consumeIfNotSticky(.command)
            if let sequence = Self.commandTextSequence(for: text) {
                return .sendBytes(sequence)
            }
            return .sendText(text)
        }
        if modifierState.isArmed(.shift) {
            modifierState.consumeIfNotSticky(.shift)
            return .sendText(text.uppercased())
        }
        return .sendText(text)
    }

    /// Resolves a backspace with no buffered/composing text, applying the
    /// armed modifier (Cmd+⌫ = kill line, Alt+⌫ = delete word, Ctrl+⌫ = DEL).
    public func resolveBackspace() -> BackspaceResolution {
        if modifierState.isArmed(.command) {
            modifierState.consumeIfNotSticky(.command)
            // Cmd+Backspace on Mac = delete to start of line (Ctrl+U).
            return .emission(.sendBytes(Data([0x15])))
        }
        if modifierState.isArmed(.alternate) {
            modifierState.consumeIfNotSticky(.alternate)
            if let sequence = TerminalKeyEncoder.encode(specialKey: .delete, modifiers: [.alternate]) {
                return .emission(.sendBytes(sequence))
            }
            return .suppressed
        }
        if modifierState.isArmed(.control) {
            modifierState.consumeIfNotSticky(.control)
            return .plainDelete
        }
        return .plainDelete
    }

    /// Resolves an accessory-bar tap: zoom buttons disarm and zoom, armed
    /// modifiers transform the tapped shortcut's output, modifier buttons
    /// toggle their armed state, and plain shortcuts emit their bytes.
    public func resolveAccessoryAction(
        _ action: TerminalInputAccessoryAction,
        now: TimeInterval
    ) -> AccessoryResolution {
        if let zoomDirection = action.zoomDirection {
            modifierState.disarmAll()
            return .zoom(zoomDirection)
        }

        if modifierState.isArmed(.control), !action.isModifier {
            modifierState.consumeIfNotSticky(.control)
            if let output = action.output {
                return .emission(.sendBytes(output))
            }
            return .none
        }

        if modifierState.isArmed(.alternate), !action.isModifier {
            modifierState.consumeIfNotSticky(.alternate)
            if let output = Self.alternateAccessoryOutput(for: action) {
                return .emission(.sendBytes(output))
            }
            return .none
        }

        if modifierState.isArmed(.command), !action.isModifier {
            modifierState.consumeIfNotSticky(.command)
            if let output = Self.commandAccessoryOutput(for: action) {
                return .emission(.sendBytes(output))
            }
            return .none
        }

        switch action {
        case .control:
            modifierState.tap(.control, now: now)
            return .none
        case .alternate:
            modifierState.tap(.alternate, now: now)
            return .none
        case .command:
            modifierState.tap(.command, now: now)
            return .none
        case .shift:
            modifierState.tap(.shift, now: now)
            return .none
        default:
            if let output = action.output {
                return .emission(.sendBytes(output))
            }
            return .none
        }
    }

    // MARK: - Sequence tables (ported verbatim from the input proxy)

    /// Ctrl+<single char> via the shared key encoder, or `nil` when the text
    /// has no control mapping.
    private static func controlSequence(for text: String) -> Data? {
        guard text.count == 1 else { return nil }
        return TerminalKeyEncoder.encode(character: text, modifiers: [.control])
    }

    /// Alt+text = ESC prefix on the UTF-8 bytes.
    private static func alternateSequence(for text: String) -> Data? {
        guard let encoded = text.data(using: .utf8), !encoded.isEmpty else { return nil }
        var sequence = Data([0x1B])
        sequence.append(encoded)
        return sequence
    }

    /// Cmd+<letter> typed through the soft keyboard, translated to
    /// Mac-terminal readline shortcuts (cmd+a = start of line, cmd+e = end,
    /// cmd+k = kill line, …).
    private static func commandTextSequence(for text: String) -> Data? {
        guard text.count == 1, let char = text.lowercased().first else { return nil }
        switch char {
        case "a": return Data([0x01]) // Ctrl+A - beginning of line
        case "e": return Data([0x05]) // Ctrl+E - end of line
        case "k": return Data([0x0B]) // Ctrl+K - kill to end of line
        case "u": return Data([0x15]) // Ctrl+U - kill to start of line
        case "w": return Data([0x17]) // Ctrl+W - delete previous word
        case "l": return Data([0x0C]) // Ctrl+L - clear screen
        case "c": return Data([0x03]) // Ctrl+C - SIGINT
        case "d": return Data([0x04]) // Ctrl+D - EOF
        default: return nil
        }
    }

    /// Alt+<accessory shortcut>: word-arrows for the arrow keys, ESC-prefixed
    /// output for the rest, nothing for modifier buttons.
    private static func alternateAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.alternate])
        case .rightArrow:
            return TerminalKeyEncoder.encode(specialKey: .rightArrow, modifiers: [.alternate])
        case .control, .alternate, .command:
            return nil
        default:
            guard let output = action.output else { return nil }
            var sequence = Data([0x1B])
            sequence.append(output)
            return sequence
        }
    }

    /// Cmd+<accessory shortcut>: readline line-start/end for the horizontal
    /// arrows, plain arrows vertically, nothing for modifier buttons.
    private static func commandAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return Data([0x01]) // Ctrl+A - beginning of line
        case .rightArrow:
            return Data([0x05]) // Ctrl+E - end of line
        case .upArrow:
            // Cmd+Up on Mac often scrolls; just send the raw arrow.
            return TerminalKeyEncoder.encode(specialKey: .upArrow, modifiers: [])
        case .downArrow:
            return TerminalKeyEncoder.encode(specialKey: .downArrow, modifiers: [])
        case .control, .alternate, .command, .shift:
            return nil
        default:
            return action.output
        }
    }
}
