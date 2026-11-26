/// One input operation against a terminal panel.
public enum CmuxTextActionDeliveryStep: Sendable, Hashable {
    /// Pastes literal text while preserving the terminal’s bracketed-paste behavior.
    case pasteText(String)
    /// Sends a named terminal key, such as Enter after a successful paste.
    case namedKey(String)
}
