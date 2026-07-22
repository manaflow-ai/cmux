import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeCommandPaletteControlCommandContext: ControlCommandContext {
    var listResolution: ControlCommandPaletteListResolution = .windowNotFound
    var runResolution: ControlCommandPaletteRunResolution = .windowNotFound
    var inlineVSCodeResolution: ControlInlineVSCodeOpenResolution = .tabManagerUnavailable

    private(set) var listRouting: ControlRoutingSelectors?
    private(set) var runCall: (routing: ControlRoutingSelectors, commandID: String)?
    private(set) var inlineVSCodeCall: (routing: ControlRoutingSelectors, directoryPath: String)?

    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution {
        listRouting = routing
        return listResolution
    }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String
    ) -> ControlCommandPaletteRunResolution {
        runCall = (routing, commandID)
        return runResolution
    }

    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution {
        inlineVSCodeCall = (routing, directoryPath)
        return inlineVSCodeResolution
    }
}
