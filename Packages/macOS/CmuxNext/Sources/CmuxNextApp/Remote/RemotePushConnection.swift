import CmuxNextDevices
import Foundation

/// The worker's pushes as this app's hub socket. Pings are answered by the worker's own
/// socket, so a send here is dropped.
nonisolated struct RemotePushConnection: DeviceHubSocketConnection {
    let channel: RemoteDeviceChannel
    private let reader: PushReader

    init(channel: RemoteDeviceChannel) {
        self.channel = channel
        reader = PushReader(channel.pushTexts)
    }

    func receive() async throws -> String {
        guard let text = await reader.next() else { throw DeviceHubSocket.Closed(code: 1000) }
        return text
    }

    func send(_ text: String) async throws {}

    func close() { channel.close() }
}

/// One iterator over a channel's pushes (an AsyncStream has one consumer).
actor PushReader {
    private var iterator: AsyncStream<String>.Iterator

    init(_ stream: AsyncStream<String>) {
        iterator = stream.makeAsyncIterator()
    }

    /// One consumer at a time: the hub socket reads its frames in order.
    func next() async -> String? {
        var current = iterator
        defer { iterator = current }
        return await current.next()
    }
}

/// The app hub's socket while cmux Remote serves this Mac: a subscription to the worker.
nonisolated struct RemotePushConnector: DeviceHubSocketConnector {
    let devices: CmuxRemoteDevices

    func connect() async throws -> any DeviceHubSocketConnection {
        try await devices.subscribe()
    }
}
