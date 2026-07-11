import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll session")
struct TerminalScrollSessionTests {
    @Test("authoritative response waits for matching local revision")
    func responseWaitsForLocalRevision() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 24, col: 2, row: 3)
        await settleTasks()
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        remote.continuation.resume(returning: response(for: remote.request, renderRevision: 10))
        await settleTasks()

        #expect(harness.delivered.isEmpty)
        #expect(session.shouldDeferLiveRenderGrid)

        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        await settleTasks()

        #expect(harness.delivered.map(\.renderRevision) == [10])
        #expect(session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 0)

        session.authoritativeDidApply(interactionEpoch: 1, clientRevision: 1)
        #expect(!session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 1)
    }

    @Test("accepted response without a frame advances the render floor")
    func responseWithoutFrameAdvancesRenderFloor() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: -6, col: 1, row: 1)
        await settleTasks()
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        remote.continuation.resume(returning: TerminalScrollResponse(
            accepted: true,
            interactionEpoch: remote.request.interactionEpoch,
            clientRevision: remote.request.clientRevision,
            renderRevision: 12,
            renderGrid: nil
        ))
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        await settleTasks()

        #expect(harness.delivered.isEmpty)
        #expect(harness.acceptedRenderRevisions == [12])
        #expect(harness.reconciliationCompletionCount == 1)
        #expect(!session.shouldDeferLiveRenderGrid)
        #expect(session.latestReconciledRevision == 1)
    }

    @Test("rapid reversals retain one in-flight and one newest batch per lane")
    func rapidReversalsStayBounded() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 10, col: 1, row: 1)
        await settleTasks()
        for index in 1...1_000 {
            session.submit(
                lines: index.isMultiple(of: 2) ? 3 : -2,
                col: index,
                row: index + 1
            )
        }
        await settleTasks()

        #expect(harness.local.started.count == 1)
        #expect(harness.remote.started.count == 1)

        let firstRemote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        firstRemote.continuation.resume(returning: response(for: firstRemote.request, renderRevision: 20))
        let firstLocal = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        firstLocal.continuation.resume(returning: true)
        await settleTasks()

        #expect(harness.local.started.count == 2)
        #expect(harness.remote.started.count == 2)
        let latestLocal = try #require(harness.local.started.last)
        let latestRemote = try #require(harness.remote.started.last)
        #expect(latestRemote.clientRevision == 1_001)
        #expect(latestLocal.lines == 500)
        #expect(latestRemote.lines == 500)
        #expect(latestRemote.directionalRuns.count == 1_000)
        #expect(latestRemote.directionalRuns.map(\.lines) == (1...1_000).map {
            $0.isMultiple(of: 2) ? 3 : -2
        })

        let finalRemote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        finalRemote.continuation.resume(returning: response(for: finalRemote.request, renderRevision: 1_001))
        let finalLocal = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        finalLocal.continuation.resume(returning: true)
        await settleTasks()

        #expect(harness.delivered.map(\.renderRevision) == [1_001])
        session.authoritativeDidApply(interactionEpoch: 1, clientRevision: 1_001)
        #expect(session.latestReconciledRevision == 1_001)
    }

    @Test("input epoch invalidates old local and remote completions")
    func inputInvalidatesOldCompletions() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: 14, col: 2, row: 4)
        await settleTasks()
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        let remote = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()

        let nextEpoch = session.invalidateForInput()
        #expect(nextEpoch == 2)
        #expect(harness.cancelLocalCount == 1)
        #expect(!session.shouldDeferLiveRenderGrid)

        remote.continuation.resume(returning: response(for: remote.request, renderRevision: 30))
        local.continuation.resume(returning: true)
        await settleTasks()

        #expect(harness.delivered.isEmpty)
        #expect(session.latestReconciledRevision == 0)
    }

    @Test("settlement requests a directional large window without a timer")
    func settlementRequestsDirectionalWindow() async throws {
        let harness = Harness()
        let session = harness.makeSession()

        session.submit(lines: -8, col: 4, row: 5)
        await settleTasks()
        let first = try #require(harness.remote.pending.first)
        harness.remote.pending.removeFirst()
        #expect(first.request.prefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 120,
            rowsAfterViewport: 600
        ))
        first.continuation.resume(returning: response(for: first.request, renderRevision: 40))
        let local = try #require(harness.local.pending.first)
        harness.local.pending.removeFirst()
        local.continuation.resume(returning: true)
        await settleTasks()

        session.interactionDidEnd()
        await settleTasks()
        let settled = try #require(harness.remote.pending.first)
        #expect(settled.request.lines == 0)
        #expect(settled.request.clientRevision == 1)
        #expect(settled.request.prefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 120,
            rowsAfterViewport: 600
        ))
    }

    @Test("disconnect recovery preserves the mounted session")
    func disconnectRecoveryPreservesMountedSession() {
        let store = MobileShellComposite.preview()
        let surfaceID = "surface-1"
        let token = store.mountTerminalScrollSession(
            surfaceID: surfaceID,
            applyLocal: { _ in true },
            cancelLocal: {}
        )
        let originalSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        let originalEpoch = originalSession?.interactionEpoch

        store.remoteClient = nil

        let recoveredSession = store.terminalScrollSessionsBySurfaceID[surfaceID]
        #expect(recoveredSession?.token == token)
        #expect(recoveredSession === originalSession)
        #expect(recoveredSession?.interactionEpoch != originalEpoch)
        #expect(recoveredSession?.shouldDeferLiveRenderGrid == false)

        store.unmountTerminalScrollSession(surfaceID: surfaceID, token: token)
    }

    private func response(
        for request: TerminalScrollRequest,
        renderRevision: UInt64
    ) -> TerminalScrollResponse {
        TerminalScrollResponse(
            accepted: true,
            interactionEpoch: request.interactionEpoch,
            clientRevision: request.clientRevision,
            renderRevision: renderRevision,
            renderGrid: try! MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: request.surfaceID,
                stateSeq: 5,
                renderRevision: renderRevision,
                columns: 20,
                rows: 2,
                text: "row-a\nrow-b"
            )
        )
    }

    private func settleTasks() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

@MainActor
private final class Harness {
    struct PendingLocal {
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct LocalStarted {
        let lines: Double
        let col: Int
        let row: Int
    }

    struct PendingRemote {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    final class LocalLane {
        var started: [LocalStarted] = []
        var pending: [PendingLocal] = []
    }

    final class RemoteLane {
        var started: [TerminalScrollRequest] = []
        var pending: [PendingRemote] = []
    }

    let local = LocalLane()
    let remote = RemoteLane()
    var delivered: [MobileTerminalRenderGridFrame] = []
    var acceptedRenderRevisions: [UInt64] = []
    var prepareIntentCount = 0
    var reconciliationCompletionCount = 0
    var cancelLocalCount = 0
    var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            applyLocal: { [local] runs in
                let latest = runs.last
                local.started.append(LocalStarted(
                    lines: runs.reduce(0) { $0 + $1.lines },
                    col: latest?.col ?? 0,
                    row: latest?.row ?? 0
                ))
                return await withCheckedContinuation { continuation in
                    local.pending.append(PendingLocal(continuation: continuation))
                }
            },
            cancelLocal: { [weak self] in
                self?.cancelLocalCount += 1
            },
            sendRemote: { [remote] request in
                remote.started.append(request)
                return await withCheckedContinuation { continuation in
                    remote.pending.append(PendingRemote(request: request, continuation: continuation))
                }
            },
            prepareIntent: { [weak self] in
                self?.prepareIntentCount += 1
            },
            deliverAuthoritative: { [weak self] frame, _, _ in
                self?.delivered.append(frame)
                return true
            },
            acceptAuthoritativeRevision: { [weak self] revision in
                self?.acceptedRenderRevisions.append(revision)
            },
            reconciliationDidComplete: { [weak self] in
                self?.reconciliationCompletionCount += 1
            },
            requestReplay: { _ in },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                self.epoch += 1
                return self.epoch
            }
        )
    }

}
