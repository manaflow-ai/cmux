/// The inline-VS-Code-domain slice of the control-command seam.
@MainActor
public protocol ControlInlineVSCodeContext: AnyObject {
    /// Opens an absolute directory path in cmux's inline VS Code browser pane.
    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution
}
