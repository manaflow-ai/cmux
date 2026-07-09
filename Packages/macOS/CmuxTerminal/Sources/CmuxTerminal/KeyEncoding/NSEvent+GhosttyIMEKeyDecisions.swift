public import AppKit

extension NSEvent {
    /// Whether the literal-space text fallback must be suppressed for this event.
    ///
    /// If AppKit consumed Shift+Space for IME/input-source switching,
    /// `interpretKeyEvents` can return without `insertText` and without a
    /// detectable layout ID change. In that case a literal space fallback must
    /// not be synthesized. `markedTextBefore`/`markedLength` describe the IME
    /// marked-text state captured by the app around the event.
    @inlinable
    public func shouldSuppressShiftSpaceFallbackText(
        markedTextBefore: Bool,
        markedLength: Int
    ) -> Bool {
        guard keyCode == 49 else { return false }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedLength == 0 else { return false }
        return true
    }

    /// Whether an extra committed-IME confirm key (Return) should be sent.
    ///
    /// Korean IME: Enter commits the syllable AND executes the command (single
    /// step). Japanese/Chinese IME: Enter only confirms the conversion; a second
    /// Enter executes. Only send the extra Return for Korean input sources, keyed
    /// off `layoutId` (`KeyboardLayout.id`). `markedTextBefore`/`markedLength`
    /// describe the IME marked-text state captured by the app around the event.
    @inlinable
    public func shouldSendCommittedIMEConfirmKey(
        markedTextBefore: Bool,
        markedLength: Int,
        layoutId: String?
    ) -> Bool {
        guard markedTextBefore, markedLength == 0 else { return false }
        guard keyCode == 36 || keyCode == 76 else { return false }
        guard let sourceId = layoutId else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }
}
