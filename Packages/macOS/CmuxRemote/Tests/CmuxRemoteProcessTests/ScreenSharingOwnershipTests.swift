// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteScreenSharing
import CmuxRemoteWire
import Foundation
import Testing

/// The worker and app can both observe the same device-hub ticket. Once the
/// app channel is present, only the app may host or approve; the worker must
/// stay a relay and leave the ticket for the app-owned host.
@MainActor
@Suite struct ScreenSharingOwnershipTests {
    @Test func appChannelMakesWorkerRelayOnlyAndRestoresAfterDisconnect() {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-test-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        #expect(agent.mayHostSessions)

        agent.setRelayOnly(true)
        #expect(agent.relayOnly)
        #expect(!agent.mayHostSessions)
        #expect(agent.banner.current == nil)

        agent.setRelayOnly(false)
        #expect(!agent.relayOnly)
        #expect(agent.mayHostSessions)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func workerChannelCountKeepsRelayOnlyUntilTheLastAppChannelCloses() {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-screen-worker-\(UUID().uuidString)")
        let worker = ScreenSharingWorker(
            layout: RemoteHostLayout(directory: root.appending(path: "layout").path),
            stateDirectory: root.appending(path: "state").path,
            keychainScope: "com.cmuxterm.test",
            headless: true
        )
        #expect(worker.appChannels == 0)
        worker.appChannelOpened()
        worker.appChannelOpened()
        #expect(worker.appChannels == 2)
        #expect(worker.agent.relayOnly)
        worker.appChannelClosed()
        #expect(worker.appChannels == 1)
        #expect(worker.agent.relayOnly)
        worker.appChannelClosed()
        #expect(worker.appChannels == 0)
        #expect(!worker.agent.relayOnly)
    }
}
