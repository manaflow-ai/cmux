import Foundation
import Testing
import XPC
@testable import CmuxTerminalRenderer

struct RendererIPCCommandTests {
    private let identity = RendererSurfaceIdentity(
        workspaceID: UUID(),
        surfaceID: UUID(),
        generation: 12
    )

    @Test
    func keyUsesDirectTypedFields() {
        let command = RendererIPCCommand.key(
            identity: identity,
            action: 1,
            modifiers: 7,
            consumedModifiers: 2,
            keycode: 36,
            text: "\r",
            unshiftedCodepoint: 13,
            composing: false
        )

        #expect(RendererIPCMessage.operation(in: command.value) == .key)
        #expect(xpc_dictionary_get_uint64(
            command.value,
            RendererIPCKey.generation
        ) == 12)
        #expect(xpc_dictionary_get_uint64(
            command.value,
            RendererIPCKey.keycode
        ) == 36)
        #expect(String(cString: xpc_dictionary_get_string(
            command.value,
            RendererIPCKey.text
        )!) == "\r")
    }

    @Test
    func coldSurfaceConfigurationRoundTrips() throws {
        let configuration = RendererSurfaceConfiguration(
            identity: identity,
            pixelWidth: 1600,
            pixelHeight: 900,
            scaleX: 2,
            scaleY: 2,
            fontSize: 13,
            workingDirectory: "/tmp",
            command: "/bin/zsh",
            initialInput: nil,
            environment: ["TERM": "xterm-ghostty"],
            waitAfterCommand: false,
            context: 2,
            manualIO: true
        )
        let command = try RendererIPCCommand.createSurface(configuration)
        let data = try #require(RendererIPCMessage.data(
            forKey: RendererIPCKey.configuration,
            in: command.value
        ))
        let decoded = try PropertyListDecoder().decode(
            RendererSurfaceConfiguration.self,
            from: data
        )

        #expect(decoded == configuration)
    }
}
