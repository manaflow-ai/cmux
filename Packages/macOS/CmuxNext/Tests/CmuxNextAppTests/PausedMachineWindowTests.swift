import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextLayout
import Foundation
import Testing

/// A relaunch restores a window on a workspace of a Cloud machine that is paused (#33483). Launch connects only
/// live machines, so nothing mirrors the workspace: the window showed a blank pane with no Resume. Opening a
/// workspace resumes its machine, as every attach does (`CloudMachineSession.attach`), so the window resumes it
/// once and shows the machine's progress, with Resume or Retry, until the workspace is mirrored.
@MainActor @Suite(.serialized)
struct PausedMachineWindowTests {
    @Test(.timeLimit(.minutes(1)))
    func aWindowOnAPausedMachinesWorkspaceResumesItAndShowsItsProgress() async throws {
        let services = MachineIconTests.services()
        services.windows.ordersWindowsIn = false
        let session = MachineIconTests.cloudMachine(services, id: "vm-paused-\(UUID().uuidString.prefix(8))")
        session.machine.status = .paused
        session.machine.pauseReason = .idle
        var resumed: [String] = []
        session.resumer = { id, _ in resumed.append(id) }
        services.windows.registry.provisional["paused-machine-window"] = ["paused-machine-ws"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "paused-machine-window"))
        defer {
            controller.teardown()
            controller.window?.close()
            session.disconnect()
        }
        // The window as a relaunch restores it: its workspace on the paused machine, which no machine mirrors.
        controller.state.machineID = session.machineID
        controller.state.workspaceID = "paused-machine-ws"
        controller.showWorkspace(requested: "paused-machine-ws")

        let view = try #require(controller.root.content as? CloudMachineProgressView,
                                "a window on a paused machine's workspace shows \(String(describing: controller.root.content)), not the machine's progress")
        #expect(view.creation.session === session)
        #expect(session.resuming, "opening the workspace did not resume its paused machine")
        for await busy in ObservationStream({ session.resuming }) where !busy { break }
        #expect(resumed == [session.machineID])
        #expect(controller.state.workspaceID == "paused-machine-ws", "the window gave up its workspace request")

        // The window's observer runs again (any input changed): one resume per open, the same view.
        controller.showWorkspace(requested: "paused-machine-ws")
        #expect(controller.root.content === view)
        #expect(resumed.count == 1)
    }

    @Test func aWindowOnALiveMachineKeepsWaitingWithoutAResume() {
        let services = MachineIconTests.services()
        services.windows.ordersWindowsIn = false
        let session = MachineIconTests.cloudMachine(services, id: "vm-live-\(UUID().uuidString.prefix(8))")
        session.machine.status = .running
        var resumed = 0
        session.resumer = { _, _ in resumed += 1 }
        services.windows.registry.provisional["live-machine-window"] = ["live-machine-ws"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "live-machine-window"))
        defer {
            controller.teardown()
            controller.window?.close()
            session.disconnect()
        }
        controller.state.machineID = session.machineID
        controller.state.workspaceID = "live-machine-ws"
        controller.showWorkspace(requested: "live-machine-ws")
        #expect(!(controller.root.content is CloudMachineProgressView))
        #expect(resumed == 0)
        #expect(!session.resuming)
    }
}
