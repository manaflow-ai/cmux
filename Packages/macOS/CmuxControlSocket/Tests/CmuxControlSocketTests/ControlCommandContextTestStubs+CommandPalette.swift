import Foundation
@testable import CmuxControlSocket

// Benign defaults for the command-palette and inline-VS-Code seams.
extension ControlCommandPaletteContext {
    func controlCommandPaletteStrings() -> ControlCommandPaletteStrings {
        ControlCommandPaletteStrings(
            windowNotFound: "Command palette window not found",
            targetUnavailable: "Command palette target unavailable",
            missingCommandID: "Missing 'command_id' parameter",
            invalidTarget: "Invalid command palette target",
            argumentsMustBeStringObject: "'arguments' must be an object of string values",
            commandNotFound: "Command palette action not found in the current context",
            missingArgumentsFormat: "Missing required action arguments: %@",
            unknownArgumentsFormat: "Unknown action arguments: %@",
            invalidArgumentValuesFormat: "Invalid values for action arguments: %@"
        )
    }

    func controlCommandPaletteList(
        routing: ControlRoutingSelectors,
        deadline: Date?
    ) async -> ControlCommandPaletteListResolution { .windowNotFound }

    func controlCommandPaletteRun(
        routing: ControlRoutingSelectors,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?,
        deadline: Date?
    ) async -> ControlCommandPaletteRunResolution { .windowNotFound }

    func controlCommandPaletteRun(
        target: ControlCommandPaletteTarget,
        commandID: String,
        arguments: [String: String],
        workingDirectory: String?,
        deadline: Date?
    ) async -> ControlCommandPaletteRunResolution { .windowNotFound }
}

extension ControlInlineVSCodeContext {
    nonisolated func controlInlineVSCodeStrings() -> ControlInlineVSCodeStrings {
        ControlInlineVSCodeStrings(
            missingPath: "Missing 'path' parameter",
            directoryNotFound: "Directory not found",
            notDirectory: "Path is not a directory",
            tabManagerUnavailable: "The inline editor is unavailable",
            workspaceNotFound: "Workspace not found",
            vscodeUnavailable: "VS Code Inline is unavailable",
            openFailed: "Failed to open VS Code Inline"
        )
    }

    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution { .tabManagerUnavailable }
}
