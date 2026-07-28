public import Foundation

/// The command-palette-domain slice of the control-command seam.
///
/// The app conformer resolves these calls against the live contribution and
/// handler registry used by Cmd+Shift+P, so the socket never maintains a
/// parallel action list.
@MainActor
public protocol ControlCommandPaletteContext: AnyObject {
    /// Returns messages resolved from the app's localization catalog.
    func controlCommandPaletteStrings() -> ControlCommandPaletteStrings

    /// Lists the palette actions available in the routed window's current UI
    /// context.
    func controlCommandPaletteList(
        routing: ControlRoutingSelectors,
        deadline: Date?
    ) async -> ControlCommandPaletteListResolution

    /// Runs one palette action through the same handler Cmd+Shift+P uses.
    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?,
        deadline: Date?
    ) async -> ControlCommandPaletteRunResolution

    /// Runs an action against the immutable identity returned by
    /// `palette.list`, without consulting current focus or selection.
    ///
    /// - Parameters:
    ///   - target: The exact identity returned by `palette.list`.
    ///   - commandID: The stable action identifier to invoke.
    ///   - arguments: Statically declared action argument values.
    ///   - workingDirectory: The caller's working directory, if available.
    /// - Returns: The typed outcome of dispatching the action.
    func controlCommandPaletteRun(
        target: ControlCommandPaletteTarget,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?,
        deadline: Date?
    ) async -> ControlCommandPaletteRunResolution
}
