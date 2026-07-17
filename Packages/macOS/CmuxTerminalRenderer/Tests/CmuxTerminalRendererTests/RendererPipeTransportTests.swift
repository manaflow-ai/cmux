import Foundation
import IOSurface
import Testing
import XPC
@testable import CmuxTerminalRenderer

@Suite struct RendererPipeTransportTests {
    @Test func primitiveFieldsRoundTripInOrder() async throws {
        let channels = try makeChannels()
        let message = RendererIPCMessage.make(.key)
        xpc_dictionary_set_uint64(message, RendererIPCKey.keycode, 42)
        xpc_dictionary_set_int64(message, RendererIPCKey.modifiers, -7)
        xpc_dictionary_set_double(message, RendererIPCKey.pressure, 0.625)
        xpc_dictionary_set_bool(message, RendererIPCKey.composing, true)
        xpc_dictionary_set_string(message, RendererIPCKey.text, "日本語")
        RendererIPCMessage.setData(
            Data([0, 1, 2, 255]),
            forKey: RendererIPCKey.data,
            in: message
        )

        guard channels.sender.send(RendererXPCObject(message)) else {
            Issue.record("primitive message was rejected by the pipe encoder")
            channels.close()
            return
        }
        let received = try #require(await channels.receiver.messages.first(where: { _ in true }))
        #expect(RendererIPCMessage.operation(in: received.value) == .key)
        #expect(xpc_dictionary_get_uint64(received.value, RendererIPCKey.keycode) == 42)
        #expect(xpc_dictionary_get_int64(received.value, RendererIPCKey.modifiers) == -7)
        #expect(xpc_dictionary_get_double(received.value, RendererIPCKey.pressure) == 0.625)
        #expect(xpc_dictionary_get_bool(received.value, RendererIPCKey.composing))
        let text = try #require(xpc_dictionary_get_string(
            received.value,
            RendererIPCKey.text
        ))
        #expect(String(cString: text) == "日本語")
        #expect(RendererIPCMessage.data(
            forKey: RendererIPCKey.data,
            in: received.value
        ) == Data([0, 1, 2, 255]))
        channels.close()
    }

    @Test func ioSurfaceCrossesBySecureMachRight() async throws {
        let channels = try makeChannels(surfacePorts: true)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 4,
            kIOSurfaceHeight: 3,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 16,
            kIOSurfaceAllocSize: 48,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        let message = RendererIPCMessage.make(.frame)
        xpc_dictionary_set_value(
            message,
            RendererIPCKey.ioSurface,
            IOSurfaceCreateXPCObject(surface)
        )

        guard channels.sender.send(RendererXPCObject(message)) else {
            Issue.record("IOSurface message was rejected by the pipe encoder")
            channels.close()
            return
        }
        let received = try #require(await channels.receiver.messages.first(where: { _ in true }))
        let object = try #require(xpc_dictionary_get_value(
            received.value,
            RendererIPCKey.ioSurface
        ))
        let decoded = try #require(IOSurfaceLookupFromXPCObject(object))
        #expect(IOSurfaceGetID(decoded) == IOSurfaceGetID(surface))
        #expect(IOSurfaceGetWidth(decoded) == 4)
        #expect(IOSurfaceGetHeight(decoded) == 3)
        channels.close()
    }

    private func makeChannels(surfacePorts: Bool = false) throws -> Channels {
        let senderToReceiver = Pipe()
        let receiverToSender = Pipe()
        let surfacePortReceiver = surfacePorts ? try RendererSurfacePortReceiver() : nil
        let surfacePortSender = try surfacePortReceiver.map {
            try RendererSurfacePortSender(serviceName: $0.serviceName)
        }
        return Channels(
            senderToReceiver: senderToReceiver,
            receiverToSender: receiverToSender,
            sender: RendererPipeTransport(
                reading: receiverToSender.fileHandleForReading,
                writing: senderToReceiver.fileHandleForWriting,
                bufferingPolicy: .unbounded,
                surfacePortSender: surfacePortSender
            ),
            receiver: RendererPipeTransport(
                reading: senderToReceiver.fileHandleForReading,
                writing: receiverToSender.fileHandleForWriting,
                bufferingPolicy: .unbounded,
                surfacePortReceiver: surfacePortReceiver
            )
        )
    }

    private struct Channels {
        let senderToReceiver: Pipe
        let receiverToSender: Pipe
        let sender: RendererPipeTransport
        let receiver: RendererPipeTransport

        func close() {
            sender.close()
            receiver.close()
        }
    }
}
