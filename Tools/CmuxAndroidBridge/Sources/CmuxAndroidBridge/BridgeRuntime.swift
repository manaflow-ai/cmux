import Foundation
import GRPC
import NIO
import NIOCore
import NIOPosix

struct BridgeRuntime {
    let arguments: BridgeArguments

    func run() async throws {
        let endpoint = try EmulatorEndpointLocator().endpoint(
            avdName: arguments.avdName,
            serial: arguments.serial
        )
        let frameBuffer = try SharedFrameBuffer(
            path: arguments.sharedMemoryPath,
            maximumWidth: arguments.width,
            maximumHeight: arguments.height,
            slotCount: BridgeProtocol.slotCount
        )
        let server = try UnixSocketServer(path: arguments.socketPath)
        defer { server.close() }
        let handle = try await server.acceptConnection()
        let writer = BridgeEventWriter(handle: handle)
        try await writer.send(BridgeEvent(
            type: "hello",
            version: BridgeProtocol.version,
            sharedMemoryPath: arguments.sharedMemoryPath,
            slotCount: BridgeProtocol.slotCount,
            slotSize: frameBuffer.slotSize
        ))

        let eventLoopGroup = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        let channel = ClientConnection
            .insecure(group: eventLoopGroup)
            .withMaximumReceiveMessageLength(frameBuffer.slotSize + 64 * 1024)
            .connect(host: "127.0.0.1", port: endpoint.port)
        let client = Android_Emulation_Control_EmulatorControllerAsyncClient(
            channel: channel,
            defaultCallOptions: CallOptions(
                customMetadata: ["authorization": "Bearer \(endpoint.bearerToken)"]
            )
        )
        let uiClient = Android_Emulation_Control_UiControllerAsyncClient(
            channel: channel,
            defaultCallOptions: CallOptions(
                customMetadata: ["authorization": "Bearer \(endpoint.bearerToken)"]
            )
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await streamFrames(
                        client: client,
                        frameBuffer: frameBuffer,
                        writer: writer
                    )
                }
                group.addTask {
                    try await processCommands(
                        from: handle,
                        client: client,
                        uiClient: uiClient,
                        frameBuffer: frameBuffer
                    )
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            try? await channel.close().get()
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
        try await channel.close().get()
        try await eventLoopGroup.shutdownGracefully()
    }

    private func streamFrames(
        client: Android_Emulation_Control_EmulatorControllerAsyncClient,
        frameBuffer: SharedFrameBuffer,
        writer: BridgeEventWriter
    ) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(arguments.width)
        format.height = UInt32(arguments.height)
        for try await frame in client.streamScreenshot(format) {
            try Task.checkCancellation()
            guard !frame.image.isEmpty else { continue }
            guard let slot = try await frameBuffer.store(frame) else { continue }
            do {
                try await writer.send(BridgeEvent(
                    type: "frame",
                    slot: slot,
                    sequence: frame.seq,
                    timestampMicroseconds: frame.timestampUs,
                    width: Int(frame.format.width),
                    height: Int(frame.format.height),
                    bytesPerRow: Int(frame.format.width) * 4,
                    bottomUp: true
                ))
            } catch {
                await frameBuffer.release(slot: slot)
                throw error
            }
        }
    }

    private func processCommands(
        from handle: FileHandle,
        client: Android_Emulation_Control_EmulatorControllerAsyncClient,
        uiClient: Android_Emulation_Control_UiControllerAsyncClient,
        frameBuffer: SharedFrameBuffer
    ) async throws {
        let decoder = JSONDecoder()
        var pending = Data()
        for try await byte in handle.bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                guard !pending.isEmpty else { continue }
                let command = try decoder.decode(BridgeCommand.self, from: pending)
                pending.removeAll(keepingCapacity: true)
                try await process(command, client: client, uiClient: uiClient, frameBuffer: frameBuffer)
            } else {
                pending.append(byte)
            }
        }
    }

    private func process(
        _ command: BridgeCommand,
        client: Android_Emulation_Control_EmulatorControllerAsyncClient,
        uiClient: Android_Emulation_Control_UiControllerAsyncClient,
        frameBuffer: SharedFrameBuffer
    ) async throws {
        switch command.type {
        case "release":
            if let slot = command.slot { await frameBuffer.release(slot: slot) }
        case "touch":
            guard let x = command.x, let y = command.y, let phase = command.phase else { return }
            var touch = Android_Emulation_Control_Touch()
            touch.x = Int32(clamping: x)
            touch.y = Int32(clamping: y)
            touch.identifier = 0
            touch.pressure = phase == "up" ? 0 : 1
            var event = Android_Emulation_Control_TouchEvent()
            event.touches = [touch]
            _ = try await client.sendTouch(event)
        case "key":
            var event = Android_Emulation_Control_KeyboardEvent()
            event.eventType = .keypress
            event.key = command.key ?? ""
            event.text = command.text ?? ""
            _ = try await client.sendKey(event)
        case "showExtendedControls":
            var entry = Android_Emulation_Control_PaneEntry()
            entry.index = .keepCurrent
            _ = try await uiClient.showExtendedControls(entry)
        default:
            return
        }
    }
}
