import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Web Inspector coordinator cleanup")
@MainActor
struct SimulatorWebInspectorCoordinatorTests {
    @Test("Highlight cleanup failure still releases the Inspector session")
    func highlightFailureStillReleases() async {
        let client = SimulatorPaneClientSpy(
            devices: [],
            failsWebInspectorHighlight: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.webInspectorIsHighlighted = true

        do {
            _ = try await coordinator.releaseWebInspectorResult()
            Issue.record("Expected the highlight cleanup error after release")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "fixture_highlight_failed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.actions() == [
            .setWebInspectorHighlight(enabled: false),
            .releaseWebInspector,
        ])
        #expect(!coordinator.webInspectorIsHighlighted)
    }

    @Test("Failed unhighlight and release preserve highlight state for retry")
    func compoundCleanupFailurePreservesHighlight() async {
        let client = SimulatorPaneClientSpy(
            devices: [],
            failsWebInspectorHighlight: true,
            failsWebInspectorRelease: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.webInspectorIsHighlighted = true

        do {
            _ = try await coordinator.releaseWebInspectorResult()
            Issue.record("Expected the Inspector release error")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "fixture_release_failed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.actions() == [
            .setWebInspectorHighlight(enabled: false),
            .releaseWebInspector,
        ])
        #expect(coordinator.webInspectorIsHighlighted)
    }

    @Test("Target closure releases the session and clears bounded responses")
    func targetClose() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let target = Self.target()
        let sessionID = UUID()
        await client.emit(.message(.webInspectorTargets(requestID: nil, [target])))
        await client.emit(.message(.webInspectorSession(
            requestID: nil,
            .attached(sessionID: sessionID, targetID: target.id)
        )))
        await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data("{\"id\":1}".utf8)
        ))))
        await Self.eventually { coordinator.webInspectorResponses.count == 1 }

        await client.emit(.message(.webInspectorTargets(requestID: nil, [])))
        await Self.eventually {
            coordinator.webInspectorSession == .detached
                && coordinator.webInspectorResponses.isEmpty
        }
    }

    @Test("Worker crash discards inspector state without affecting the host coordinator")
    func workerCrash() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let target = Self.target()
        await client.emit(.message(.webInspectorTargets(requestID: nil, [target])))
        await client.emit(.message(.webInspectorSession(
            requestID: nil,
            .attached(sessionID: UUID(), targetID: target.id)
        )))

        await client.emit(.workerStopped)
        await Self.eventually {
            coordinator.status == .workerCrashed
                && coordinator.webInspectorTargets.isEmpty
                && coordinator.webInspectorSession == .detached
        }
    }

    @Test("A response over the UI cap still completes its correlated command as truncated")
    func truncatedCommandResponseCompletes() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let sessionID = UUID()
        await client.emit(.message(.capabilities([.webInspector])))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.webInspectorSession(
            requestID: nil,
            .attached(sessionID: sessionID, targetID: "target")
        )))
        await Self.eventually { coordinator.webInspectorSession != .detached }

        let responseTask = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":42,"method":"Runtime.evaluate"}"#
            )
        }
        for _ in 0..<100 {
            if await client.actions().contains(where: {
                if case .sendWebInspectorMessage = $0 { return true }
                return false
            }) { break }
            await Task.yield()
        }
        let raw = "{\"padding\":\""
            + String(
                repeating: "x",
                count: SimulatorWebInspectorResponseBuffer.maximumResponseBytes + 1_000
            )
            + "\",\"id\":42,\"result\":{\"value\":true}}"
        let chunks = SimulatorWebInspectorMessageChunker(maximumPayloadLength: 64 * 1024).chunks(
            sessionID: sessionID,
            messageID: UUID(),
            payload: Data(raw.utf8)
        )
        for chunk in chunks { await client.emit(.message(.webInspectorMessage(chunk))) }

        let response = try await responseTask.value
        #expect(response.isTruncated)
        #expect(response.text.utf8.count == SimulatorWebInspectorResponseBuffer.maximumResponseBytes)
    }

    @Test("A nested notification id cannot complete a pending command")
    func nestedNotificationDoesNotCompleteCommand() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let sessionID = UUID()
        await client.emit(.message(.capabilities([.webInspector])))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.webInspectorSession(
            requestID: nil, .attached(sessionID: sessionID, targetID: "target")
        )))
        await Self.eventually { coordinator.webInspectorSession != .detached }

        let responseTask = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":"abc","method":"Runtime.evaluate"}"#
            )
        }
        await Self.eventually { coordinator.pendingWebInspectorResponses.count == 1 }
        await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data(#"{"method":"DOM.updated","params":{"request":{"id":"abc"}}}"#.utf8)
        ))))
        #expect(coordinator.pendingWebInspectorResponses.count == 1)

        await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data(#"{"id":"abc","result":{"ok":true}}"#.utf8)
        ))))
        let response = try await responseTask.value
        #expect(response.text.contains(#""ok":true"#))
    }

    @Test("A cancelled command ID stays retired until its late response is discarded")
    func cancelledRequestIDCannotCaptureLateResponse() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let sessionID = UUID()
        await client.emit(.message(.capabilities([.webInspector])))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.webInspectorSession(
            requestID: nil, .attached(sessionID: sessionID, targetID: "target")
        )))
        await Self.eventually { coordinator.webInspectorSession != .detached }

        let first = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":91,"method":"Runtime.evaluate"}"#
            )
        }
        await Self.eventually { coordinator.pendingWebInspectorResponses.count == 1 }
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Expected cancellation")
        } catch {}

        do {
            _ = try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":91,"method":"Runtime.evaluate"}"#
            )
            Issue.record("Expected retired ID rejection")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "web_inspector_request_id_in_use")
        }

        await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data(#"{"id":91,"result":{"stale":true}}"#.utf8)
        ))))
        await Self.eventually { coordinator.retiredWebInspectorRequestIDs.isEmpty }

        let replacement = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":91,"method":"Runtime.evaluate"}"#
            )
        }
        await Self.eventually { coordinator.pendingWebInspectorResponses.count == 1 }
        await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data(#"{"id":91,"result":{"fresh":true}}"#.utf8)
        ))))
        let response = try await replacement.value
        #expect(response.text.contains(#""fresh":true"#))
    }

    @Test("Cancelling a response wait cancels its deferred worker send")
    func cancellationStopsDeferredSend() async {
        let client = SimulatorPaneClientSpy(devices: [], delaysWebInspectorSend: true)
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let sessionID = UUID()
        await client.emit(.message(.capabilities([.webInspector])))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.webInspectorSession(
            requestID: nil, .attached(sessionID: sessionID, targetID: "target")
        )))
        await Self.eventually { coordinator.webInspectorSession != .detached }

        let responseTask = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":92,"method":"Runtime.evaluate"}"#
            )
        }
        for _ in 0..<100 {
            if await client.hasDelayedWebInspectorSend() { break }
            await Task.yield()
        }
        responseTask.cancel()
        do {
            _ = try await responseTask.value
            Issue.record("Expected cancellation")
        } catch {}

        for _ in 0..<100 {
            if await client.webInspectorSendCancellationCount() == 1 { break }
            await Task.yield()
        }
        #expect(await client.webInspectorSendCancellationCount() == 1)
    }

    @Test("Response-buffer overflow fails correlated commands immediately")
    func responseOverflowFailsCommand() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let sessionID = UUID()
        await client.emit(.message(.capabilities([.webInspector])))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.webInspectorSession(
            requestID: nil, .attached(sessionID: sessionID, targetID: "target")
        )))
        await Self.eventually { coordinator.webInspectorSession != .detached }

        let responseTask = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":77,"method":"Runtime.evaluate"}"#
            )
        }
        await Self.eventually { coordinator.pendingWebInspectorResponses.count == 1 }
        for _ in 0...SimulatorWebInspectorResponseBuffer.maximumPendingMessageCount {
            await client.emit(.message(.webInspectorMessage(SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: UUID(),
                sequence: 0,
                isFinal: false,
                payload: Data("{".utf8)
            ))))
        }

        do {
            _ = try await responseTask.value
            Issue.record("Expected overflow failure")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "web_inspector_response_overflow")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Closing the pane cancels an injected Web Inspector response deadline")
    func closeCancelsResponseDeadline() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let sleeper = CancellableProcessSleeper()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: sleeper
        )
        await coordinator.start()

        let responseTask = Task { @MainActor in
            try await coordinator.sendWebInspectorMessageAwaitingResponse(
                #"{"id":88,"method":"Runtime.evaluate"}"#
            )
        }
        await Self.eventually { coordinator.pendingWebInspectorResponses.count == 1 }
        for _ in 0..<100 {
            if await sleeper.hasStarted { break }
            await Task.yield()
        }

        await coordinator.close()
        do {
            _ = try await responseTask.value
            Issue.record("Expected pane closure to fail the pending response")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "web_inspector_session_ended")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        for _ in 0..<100 {
            if await sleeper.wasCancelled { break }
            await Task.yield()
        }
        #expect(await sleeper.wasCancelled)
    }

    private static func target() -> SimulatorWebInspectorTarget {
        SimulatorWebInspectorTarget(
            id: "APP|1",
            applicationIdentifier: "APP",
            pageIdentifier: 1,
            title: "Fixture",
            url: "https://example.test",
            type: "WIRTypeWebPage",
            applicationName: "Example",
            bundleIdentifier: "com.example.app",
            isInUse: false
        )
    }

    private static func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}
