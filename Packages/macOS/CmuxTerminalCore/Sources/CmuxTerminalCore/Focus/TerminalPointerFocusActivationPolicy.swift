public import Foundation

/// Decides whether a terminal pointer-down should be delivered to Ghostty.
public struct TerminalPointerFocusActivationPolicy: Sendable {
    /// Creates a pointer-focus activation policy.
    public init() {}

    /// Returns whether terminal mouse reporting owns this pointer sequence.
    ///
    /// A captured Ghostty surface keeps ownership across a focus transfer;
    /// otherwise only a click on the surface that was already focused is
    /// delivered to the terminal. This preserves cmux's focus-only behavior
    /// for ordinary clicks on an unfocused, non-captured pane.
    ///
    /// - Parameters:
    ///   - mouseCaptured: Whether Ghostty currently has mouse reporting enabled.
    ///   - wasFocusedBeforePointerDown: Whether this surface owned terminal
    ///     focus before AppKit processed the pointer-down.
    /// - Returns: `true` when the press/release sequence belongs to Ghostty.
    public func shouldForwardToTerminal(
        mouseCaptured: Bool,
        wasFocusedBeforePointerDown: Bool
    ) -> Bool {
        mouseCaptured || wasFocusedBeforePointerDown
    }

    /// Returns whether the focused panel identity matches the pointer target.
    ///
    /// - Parameters:
    ///   - currentPanelId: The panel receiving the pointer-down.
    ///   - focusedPanelId: The panel that owns the container's current focus.
    /// - Returns: `true` only when both identities are present and equal.
    public func shouldForwardToTerminal(currentPanelId: UUID, focusedPanelId: UUID?) -> Bool {
        focusedPanelId == currentPanelId
    }
}
