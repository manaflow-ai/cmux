import CmuxNextDevices
import Foundation

/// The share host's pushes as this app's hub socket. Pings are answered by the share host's own
/// socket, so a send here is dropped.
nonisolated struct DevicePushConnection: DeviceHubSocketConnection {
    let channel: DeviceLineChannel

    func receive() async throws -> String {
        guard let text = await channel.nextPush() else { throw DeviceHubSocket.Closed(code: 1000) }
        return text
    }

    func send(_ text: String) async throws {}

    func close() { channel.close() }
}

/// The app hub's socket while the share host serves this Mac's device: a subscription to it.
nonisolated struct DevicePushConnector: DeviceHubSocketConnector {
    let devices: ShareHostDevices

    func connect() async throws -> any DeviceHubSocketConnection {
        try await devices.subscribe()
    }
}
