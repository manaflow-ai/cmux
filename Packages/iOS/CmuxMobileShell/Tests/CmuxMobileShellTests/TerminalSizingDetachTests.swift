import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxTerminalSizing
import Foundation
import Testing
@testable import CmuxMobileShell

// Shared terminal sizing on the phone (docs/shared-terminal-sizing.md):
// a `disconnected-by` detach must stop viewport, input and replay for that
// surface and never reconnect it without the user, while a `network` detach
// keeps today's automatic recovery.

private let surfaceID = "live-terminal"

@MainActor
private func detachedEnvelope(reason: String, by: [String: Any]? = nil) throws -> MobileEventEnvelope {
    var payload: [String: Any] = [
        "surface_id": surfaceID,
        "reason": reason,
        "at": "2026-09-27T14:05:00Z",
    ]
    payload["by"] = by ?? NSNull()
    return MobileEventEnvelope(
        topic: MobileShellComposite.terminalDetachedTopic,
        payloadJSON: try JSONSerialization.data(withJSONObject: payload),
        streamID: nil
    )
}

@MainActor
@Test func terminalViewportReportCarriesDeviceIdentity() async throws {
    let router = LivenessHostRouter()
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initial = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initial.streamToken)
    let report = try #require(await router.requests(for: "mobile.terminal.viewport").last)
    #expect(report.deviceKind == "iphone" || report.deviceKind == "ipad")
    #expect(report.deviceName?.isEmpty == false)
}

@MainActor
@Test func disconnectedByDetachStopsTrafficAndNeverReplays() async throws {
    let router = LivenessHostRouter()
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initial = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initial.streamToken)

    store.handleTerminalDetachedEvent(try detachedEnvelope(
        reason: "disconnected-by",
        by: ["user_id": "u_maya", "display_name": "Maya Ortiz", "device_name": "Mac Studio"]
    ))
    #expect(!store.terminalAllowsTraffic(surfaceID: surfaceID))
    guard case let .detached(reason, at)? = store.terminalSizing(for: surfaceID)?.attachment else {
        Issue.record("surface must be detached")
        return
    }
    #expect(reason == .disconnectedBy(TerminalDetachActor(
        userID: "u_maya", displayName: "Maya Ortiz", deviceName: "Mac Studio"
    )))
    #expect(at != nil)

    let replays = await router.count(of: "mobile.terminal.replay")
    let viewports = await router.count(of: "mobile.terminal.viewport")
    let inputs = await router.count(of: "terminal.input")

    // Every recovery trigger the surface can fire while detached.
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    store.requestColdAttachTerminalReplay(surfaceID: surfaceID)
    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: surfaceID)
    let held = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(held?.columns == 80)
    #expect(held?.rows == 48, "a detached surface keeps its last granted grid")

    let replayed = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replays + 1,
        timeoutNanoseconds: 300_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayed, "a disconnected-by detach must not replay without the user")
    #expect(await router.count(of: "mobile.terminal.viewport") == viewports)
    #expect(await router.count(of: "terminal.input") == inputs)
    #expect(!store.terminalAllowsTraffic(surfaceID: surfaceID))
}

@MainActor
@Test func networkDetachKeepsAutomaticRecovery() async throws {
    let router = LivenessHostRouter()
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initial = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initial.streamToken)
    let replays = await router.count(of: "mobile.terminal.replay")
    await router.enqueueReplayTexts(["recovery-replay"])

    store.handleTerminalDetachedEvent(try detachedEnvelope(reason: "network"))
    #expect(store.terminalAllowsTraffic(surfaceID: surfaceID))

    let replayed = await router.waitForCount(of: "mobile.terminal.replay", atLeast: replays + 1)
    #expect(replayed, "a network detach must recover through the normal replay path")
    let chunk = try #require(await iterator.next())
    #expect(String(data: chunk.data, encoding: .utf8) == "recovery-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
    let recovered = try await pollUntil {
        store.terminalSizing(for: surfaceID)?.attachment == .attached
    }
    #expect(recovered, "a replay answer ends the reconnecting state")
}

@MainActor
@Test func sizeStatePushIsKeptPerSurface() async throws {
    let router = LivenessHostRouter()
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initial = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initial.streamToken)
    let payload: [String: Any] = [
        "surface_id": surfaceID,
        "self_participant_id": "mobile:phone",
        "state": [
            "generation": 3, "cols": 118, "rows": 38, "reason": "latest", "owners": ["c3"],
            "policy": ["mode": "latest", "priority": [], "fixed": NSNull()],
            "participants": [
                ["id": "c3", "user_id": "u_maya", "display_name": "Maya Ortiz",
                 "device_kind": "mac", "device_name": "Mac Studio",
                 "viewport": ["cols": 118, "rows": 38], "counts": true],
                ["id": "mobile:phone", "user_id": "u_maya", "device_kind": "iphone",
                 "device_name": "iPhone", "viewport": ["cols": 80, "rows": 48], "counts": false],
            ],
        ] as [String: Any],
    ]
    store.handleTerminalSizeStateEvent(MobileEventEnvelope(
        topic: MobileShellComposite.terminalSizeStateTopic,
        payloadJSON: try JSONSerialization.data(withJSONObject: payload),
        streamID: nil
    ))
    let presentation = try #require(store.terminalSizingPresentation(for: surfaceID))
    #expect(presentation.grid == TerminalGridSize(cols: 118, rows: 38))
    #expect(presentation.owner?.id == "c3")
    #expect(presentation.hiddenColumns == 38)
    #expect(presentation.otherParticipants.map(\.id) == ["c3"])
    // The grid moved away from the 80x48 the phone renders, so the mounted
    // surface is asked to re-report its viewport.
    #expect(store.terminalSizing(for: surfaceID)?.viewportReassertGeneration == 1)
    #expect(store.terminalSizingPresentation(for: "other-surface") == nil)
}
