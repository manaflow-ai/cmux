@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Observation
import os
import Testing

/// A person's Close Workspace on a machine that is not connected (a paused Cloud VM): the close
/// used to fail "not connected" at once and the row came back, so the sidebar's close button did
/// nothing. Now the close waits for the machine (`DaemonService.failureOnceConnected`) and runs
/// when it connects; a machine that leaves the app ends the wait, and the close then fails (the row
/// lists again). A daemon that was never started is the not-connected machine here.
@MainActor @Suite(.serialized) struct OfflineWorkspaceCloseTests {
    @MainActor @Observable final class Presence {
        var present = true
        var finished = false
    }

    @Test func aCloseOnANotConnectedMachineWaitsAndSendsNothing() async {
        let daemon = DaemonService(machineID: "cloud:paused"), presence = Presence(), sent = OSAllocatedUnfairLock(initialState: false)
        let close = Task { @MainActor in
            let failure = await daemon.failureOnceConnected("close-workspace", waits: true, while: { presence.present }) { _ in sent.withLock { $0 = true } }
            presence.finished = true
            return failure
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!presence.finished, "the close returned while its machine was not connected")
        #expect(!sent.withLock { $0 })
        // The machine leaves the app (sign-out, removed): the wait ends and the close fails, nothing sent.
        presence.present = false
        let failure = await close.value
        #expect(presence.finished)
        #expect(failure != nil)
        #expect(!sent.withLock { $0 })
    }

    @Test func aCloseThatDoesNotWaitFailsAtOnce() async {
        let daemon = DaemonService(machineID: "cloud:paused")
        let sent = OSAllocatedUnfairLock(initialState: false)
        let failure = await daemon.failureOnceConnected("close-workspace", waits: false, while: { true }) { _ in sent.withLock { $0 = true } }
        #expect(failure != nil)
        #expect(!sent.withLock { $0 })
    }
}
