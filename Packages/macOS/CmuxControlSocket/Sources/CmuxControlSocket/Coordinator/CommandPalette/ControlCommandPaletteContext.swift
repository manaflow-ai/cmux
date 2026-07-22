/// The command-palette-domain slice of the control-command seam.
///
/// The app conformer resolves these calls against the live contribution and
/// handler registry used by Cmd+Shift+P, so the socket never maintains a
/// parallel action list.
@MainActor
public protocol ControlCommandPaletteContext: AnyObject {
    /// Lists the palette actions available in the routed window's current UI
    /// context.
    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution

    /// Runs one palette action through the same handler Cmd+Shift+P uses.
    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution
}
