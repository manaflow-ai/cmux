public import AppKit
public import CmuxTerminalDomain

/// Translates AppKit keyboard and text-input values into Ghostty-free runtime DTOs.
///
/// The frontend remains the `NSTextInputClient` owner, while physical-key identity,
/// committed text, and marked text cross the process boundary as domain values.
@MainActor
public struct TerminalFrontendInputTranslator {
    private let keyMap: TerminalMacOSKeyMap

    /// Creates an input translator with the generated canonical macOS key table.
    ///
    /// - Parameter keyMap: The physical-key map derived from Ghostty's checked-in table.
    public init(keyMap: TerminalMacOSKeyMap = TerminalMacOSKeyMap()) {
        self.keyMap = keyMap
    }

    /// Translates one AppKit key event into the persistent runtime's semantic key event.
    ///
    /// `interpretedText` is supplied by the owning `NSTextInputClient`, because AppKit's
    /// input manager decides whether a physical event commits text or updates preedit.
    ///
    /// - Parameters:
    ///   - event: The original AppKit physical-key event.
    ///   - interpretedText: Text committed by AppKit for this event, if any.
    ///   - consumedModifierFlags: Modifiers AppKit consumed while producing the text.
    ///   - unshiftedCodepoint: A keyboard-layout-derived codepoint override.
    ///   - action: An explicit phase override for synthesized events.
    /// - Returns: A Ghostty-free semantic key event ready for ordered runtime ingress.
    public func keyEvent(
        from event: NSEvent,
        interpretedText: String?,
        consumedModifierFlags: NSEvent.ModifierFlags = [],
        unshiftedCodepoint: UInt32? = nil,
        action: TerminalExternalKeyAction? = nil
    ) -> TerminalExternalKeyEvent {
        let modifiers = modifiers(from: event.modifierFlags)
        let consumedModifiers = textConsumedModifiers(
            from: consumedModifierFlags
        ).intersection(modifiers)

        return TerminalExternalKeyEvent(
            key: keyMap.key(for: event.keyCode).rawValue,
            modifiers: modifiers,
            consumedModifiers: consumedModifiers,
            text: interpretedText.flatMap { $0.isEmpty ? nil : $0 },
            unshiftedCodepoint: unshiftedCodepoint ?? derivedUnshiftedCodepoint(from: event),
            action: action ?? derivedAction(from: event)
        )
    }

    /// Splits one AppKit committed-text value into ordered runtime input operations.
    ///
    /// Return, Tab, and non-literal Escape stay physical named keys so terminal modes
    /// and bindings remain daemon-owned. Every other scalar remains in UTF-8 text runs.
    ///
    /// - Parameters:
    ///   - value: The `String` or `NSAttributedString` passed to `insertText`.
    ///   - preserveLiteralEscape: Whether Escape remains a byte in its text run.
    /// - Returns: FIFO input values to enqueue in order, or an empty array for an unsupported value.
    public func committedInputs(
        from value: Any,
        preserveLiteralEscape: Bool
    ) -> [TerminalExternalInput] {
        guard let text = string(from: value), !text.isEmpty else { return [] }

        var inputs: [TerminalExternalInput] = []
        var bufferedText = ""
        var previousWasCarriageReturn = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCarriageReturn {
                    flushCommittedText(&bufferedText, into: &inputs)
                    inputs.append(.namedKey("enter"))
                }
                previousWasCarriageReturn = false
            case 0x0D:
                flushCommittedText(&bufferedText, into: &inputs)
                inputs.append(.namedKey("enter"))
                previousWasCarriageReturn = true
            case 0x09:
                flushCommittedText(&bufferedText, into: &inputs)
                inputs.append(.namedKey("tab"))
                previousWasCarriageReturn = false
            case 0x1B where !preserveLiteralEscape:
                flushCommittedText(&bufferedText, into: &inputs)
                inputs.append(.namedKey("escape"))
                previousWasCarriageReturn = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCarriageReturn = false
            }
        }

        flushCommittedText(&bufferedText, into: &inputs)
        return inputs
    }

    /// Translates AppKit marked text and selection into UTF-16 preedit coordinates.
    ///
    /// - Parameters:
    ///   - value: The `String` or `NSAttributedString` passed to `setMarkedText`.
    ///   - selectedRange: AppKit's selection inside the marked-text buffer.
    /// - Returns: Clamped preedit state, or `nil` when marked text is empty or unsupported.
    public func preedit(
        from value: Any,
        selectedRange: NSRange
    ) -> TerminalExternalPreedit? {
        guard let text = string(from: value), !text.isEmpty else { return nil }

        let textLength = text.utf16.count
        let selectionLocation: Int
        if selectedRange.location == NSNotFound {
            selectionLocation = textLength
        } else {
            selectionLocation = min(max(selectedRange.location, 0), textLength)
        }
        let selectionLength = min(
            max(selectedRange.length, 0),
            textLength - selectionLocation
        )

        return TerminalExternalPreedit(
            text: text,
            selectionStartUTF16: UInt32(clamping: selectionLocation),
            selectionLengthUTF16: UInt32(clamping: selectionLength),
            caretUTF16: UInt32(clamping: selectionLocation + selectionLength)
        )
    }

    private func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> TerminalExternalKeyModifiers {
        var result: TerminalExternalKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }

        let rawValue = flags.rawValue
        if rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { result.insert(.rightShift) }
        if rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 { result.insert(.rightControl) }
        if rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { result.insert(.rightOption) }
        if rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 { result.insert(.rightCommand) }
        return result
    }

    private func textConsumedModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> TerminalExternalKeyModifiers {
        var result: TerminalExternalKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        return result
    }

    private func derivedAction(from event: NSEvent) -> TerminalExternalKeyAction {
        switch event.type {
        case .keyUp:
            return .release
        case .keyDown:
            return event.isARepeat ? .repeat : .press
        case .flagsChanged:
            return modifierIsActive(for: event) ? .press : .release
        default:
            return .press
        }
    }

    private func modifierIsActive(for event: NSEvent) -> Bool {
        let rawValue = event.modifierFlags.rawValue
        switch event.keyCode {
        case 54:
            return rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        case 55:
            return rawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
        case 56:
            return rawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
        case 57:
            return event.modifierFlags.contains(.capsLock)
        case 58:
            return rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        case 59:
            return rawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
        case 60:
            return rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 61:
            return rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case 62:
            return rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 63:
            return event.modifierFlags.contains(.function)
        default:
            return !event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .isEmpty
        }
    }

    private func derivedUnshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }
        let characters = event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
            ?? event.characters
        guard let scalar = characters?.unicodeScalars.first else { return 0 }
        guard scalar.value >= 0x20, scalar.value != 0x7F else { return 0 }
        guard !(0xF700...0xF8FF).contains(scalar.value) else { return 0 }
        return scalar.value
    }

    private func string(from value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private func flushCommittedText(
        _ bufferedText: inout String,
        into inputs: inout [TerminalExternalInput]
    ) {
        guard !bufferedText.isEmpty else { return }
        inputs.append(.text(TerminalExternalTextInput(
            text: bufferedText,
            kind: .committed
        )))
        bufferedText.removeAll(keepingCapacity: true)
    }
}
