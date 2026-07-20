import Foundation
import Testing
import XPC
@testable import CmuxTerminalRenderer

struct RendererIPCMessageTests {
    @Test
    func roundTripsHotPathFieldsWithoutSerializationContainer() throws {
        let workspaceID = UUID()
        let bytes = Data([0, 1, 2, 127, 255])
        let message = RendererIPCMessage.make(.key)
        RendererIPCMessage.setUUID(workspaceID, forKey: RendererIPCKey.workspaceID, in: message)
        RendererIPCMessage.setData(bytes, forKey: RendererIPCKey.data, in: message)

        #expect(RendererIPCMessage.operation(in: message) == .key)
        #expect(RendererIPCMessage.uuid(
            forKey: RendererIPCKey.workspaceID,
            in: message
        ) == workspaceID)
        #expect(RendererIPCMessage.data(
            forKey: RendererIPCKey.data,
            in: message
        ) == bytes)
    }

    @Test
    func rejectsMismatchedProtocolVersion() {
        let message = RendererIPCMessage.make(.ping)
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.protocolVersion,
            RendererIPCProtocol.version + 1
        )

        #expect(RendererIPCMessage.operation(in: message) == nil)
    }
}
