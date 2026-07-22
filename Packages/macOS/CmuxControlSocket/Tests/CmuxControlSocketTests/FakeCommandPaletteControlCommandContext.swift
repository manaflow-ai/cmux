import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeCommandPaletteControlCommandContext: ControlCommandContext {
    var paletteStrings = ControlCommandPaletteStrings(
        windowNotFound: "palette window unavailable",
        missingCommandID: "missing palette command id",
        argumentsMustBeStringObject: "palette arguments must be strings",
        commandNotFound: "palette command unavailable",
        missingArgumentsFormat: "missing: %@",
        unknownArgumentsFormat: "unknown: %@",
        invalidArgumentValuesFormat: "invalid: %@"
    )
    var listResolution: ControlCommandPaletteListResolution = .windowNotFound
    var runResolution: ControlCommandPaletteRunResolution = .windowNotFound
    var inlineVSCodeResolution: ControlInlineVSCodeOpenResolution = .tabManagerUnavailable

    private(set) var listRouting: ControlRoutingSelectors?
    private(set) var runCall: (
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    )?
    private(set) var inlineVSCodeCall: (routing: ControlRoutingSelectors, directoryPath: String)?

    func controlCommandPaletteStrings() -> ControlCommandPaletteStrings {
        paletteStrings
    }

    func controlCommandPaletteList(
        routing: ControlRoutingSelectors
    ) -> ControlCommandPaletteListResolution {
        listRouting = routing
        return listResolution
    }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?
    ) -> ControlCommandPaletteRunResolution {
        runCall = (routing, commandID, arguments, workingDirectory)
        return runResolution
    }

    nonisolated func controlInlineVSCodeStrings() -> ControlInlineVSCodeStrings {
        ControlInlineVSCodeStrings(
            missingPath: "missing inline path",
            directoryNotFound: "inline directory not found",
            notDirectory: "inline path is not a directory",
            tabManagerUnavailable: "inline editor unavailable",
            workspaceNotFound: "inline workspace not found",
            vscodeUnavailable: "inline VS Code unavailable",
            openFailed: "inline open failed"
        )
    }

    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution {
        inlineVSCodeCall = (routing, directoryPath)
        return inlineVSCodeResolution
    }
}
