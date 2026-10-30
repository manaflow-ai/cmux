import CmuxNextDevices
import Foundation

/// The worker's pushes as this app's hub socket. Pings are answered by the worker's own
/// socket, so a send here is dropped.
nonisolated struct RemotePushConnection: DeviceHubSocketConnection {
    let channel: RemoteDeviceChannel

    func receive() async throws -> String {
        guard let text = await channel.nextPush() else { throw DeviceHubSocket.Closed(code: 1000) }
        return text
    }

    func send(_ text: String) async throws {}

    func close() { channel.close() }
}

/// The app hub's socket while cmux Remote serves this Mac: a subscription to the worker.
nonisolated struct RemotePushConnector: DeviceHubSocketConnector {
    let devices: CmuxRemoteDevices

    func connect() async throws -> any DeviceHubSocketConnection {
        try await devices.subscribe()
    }
}
