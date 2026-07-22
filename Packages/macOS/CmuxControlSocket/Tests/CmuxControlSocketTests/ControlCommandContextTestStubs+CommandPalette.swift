import Foundation
@testable import CmuxControlSocket

// Benign defaults for the command-palette and inline-VS-Code seams.
extension ControlCommandPaletteContext {
    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution { .windowNotFound }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution { .windowNotFound }
}

extension ControlInlineVSCodeContext {
    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution { .tabManagerUnavailable }
}
