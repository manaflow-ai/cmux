public import Foundation

/// Ordered command source consumed by a workspace renderer runtime.
public protocol RendererWorkerListening: AnyObject, Sendable {
    var messages: AsyncStream<RendererWorkerMessage> { get }
}

/// Worker-side adapter for the direct stdin/stdout binary channel.
public final class RendererWorkerStdioListener: RendererWorkerListening, @unchecked Sendable {
    public let messages: AsyncStream<RendererWorkerMessage>

    private let transport: RendererPipeTransport
    private let relayTask: Task<Void, Never>

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        surfacePortServiceName: String
    ) throws {
        let surfacePortSender = try RendererSurfacePortSender(
            serviceName: surfacePortServiceName
        )
        transport = RendererPipeTransport(
            reading: input,
            writing: output,
            bufferingPolicy: .unbounded,
            surfacePortSender: surfacePortSender
        )
        let pair = AsyncStream<RendererWorkerMessage>.makeStream(bufferingPolicy: .unbounded)
        messages = pair.stream
        let transport = transport
        relayTask = Task.detached {
            for await message in transport.messages {
                pair.continuation.yield(RendererWorkerMessage(
                    message: message,
                    reply: { transport.send($0) }
                ))
            }
            pair.continuation.finish()
        }
    }

    deinit {
        relayTask.cancel()
        transport.close()
    }
}
