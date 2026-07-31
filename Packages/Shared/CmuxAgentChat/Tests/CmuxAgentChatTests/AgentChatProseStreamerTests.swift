import Foundation
import XCTest

@testable import CmuxAgentChat

@MainActor
final class AgentChatProseStreamerTests: XCTestCase {
    private actor SnapshotGate {
        private var continuation: CheckedContinuation<[String]?, Never>?

        func waitForRows() async -> [String]? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(rows: [String]?) {
            continuation?.resume(returning: rows)
            continuation = nil
        }
    }

    func testStreamsOnlyAfterSurfaceChange() async throws {
        let surfaceID = UUID()
        let sessionID = "session-with-event-driven-streaming"
        let expectedText = "The sky is blue."
        let screenRows = Self.codexRows(answer: expectedText)

        let emittedFrame = expectation(description: "streaming prose frame emitted")
        var emittedFrames: [ChatSessionEventFrame] = []
        var didFulfillEmittedFrame = false
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                emittedFrames.append(frame)
                if !didFulfillEmittedFrame {
                    didFulfillEmittedFrame = true
                    emittedFrame.fulfill()
                }
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == surfaceID ? screenRows : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        await Task.yield()
        XCTAssertTrue(emittedFrames.isEmpty)

        streamer.surfaceDidChange(surfaceID)
        await fulfillment(of: [emittedFrame], timeout: 1.0)

        let frame = try XCTUnwrap(emittedFrames.first)
        XCTAssertEqual(frame.sessionID, sessionID)
        guard case .streamingProse(let message?) = frame.event else {
            return XCTFail("Expected a streaming prose preview frame")
        }
        XCTAssertEqual(message.id, "stream:\(sessionID)")
        XCTAssertEqual(message.role, .agent)
        guard case .prose(let prose) = message.kind else {
            return XCTFail("Expected prose preview content")
        }
        XCTAssertEqual(prose.text, expectedText)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testCoalescesSurfaceChangesToNewestSnapshot() async throws {
        let surfaceID = UUID()
        let sessionID = "session-coalesces-newest-screen"
        let firstText = "Older partial answer."
        let newestText = "Newest partial answer."
        var rows = Self.codexRows(answer: firstText)
        var snapshotCount = 0
        var emittedFrames: [ChatSessionEventFrame] = []
        let emittedFrame = expectation(description: "latest coalesced preview emitted")
        var didFulfillEmittedFrame = false
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                emittedFrames.append(frame)
                if !didFulfillEmittedFrame {
                    didFulfillEmittedFrame = true
                    emittedFrame.fulfill()
                }
            },
            snapshot: { requestedSurfaceID in
                guard requestedSurfaceID == surfaceID else { return nil }
                snapshotCount += 1
                return rows
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        streamer.surfaceDidChange(surfaceID)
        rows = Self.codexRows(answer: newestText)
        streamer.surfaceDidChange(surfaceID)

        await fulfillment(of: [emittedFrame], timeout: 1.0)

        XCTAssertEqual(snapshotCount, 1)
        guard case .streamingProse(let message?) = emittedFrames.first?.event,
              case .prose(let prose) = message.kind else {
            return XCTFail("Expected one coalesced preview")
        }
        XCTAssertEqual(prose.text, newestText)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testDoesNotSnapshotWithoutSubscribers() async throws {
        let surfaceID = UUID()
        let sessionID = "session-no-subscriber-no-demand"
        var snapshotCount = 0
        let streamer = AgentChatProseStreamer(
            emit: { _ in XCTFail("No subscriber means no preview emission") },
            snapshot: { _ in
                snapshotCount += 1
                return Self.codexRows(answer: "Should not be read.")
            },
            hasSubscribers: { false },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        XCTAssertTrue(streamer.hasActiveUnsettledTurns)
        streamer.surfaceDidChange(surfaceID)
        streamer.terminalDidTick()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(snapshotCount, 0)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testGlobalTickReachesHiddenSurfaceTurns() async throws {
        let surfaceID = UUID()
        let sessionID = "session-hidden-surface-tick"
        let expectedText = "Hidden surface still streams."
        let emittedFrame = expectation(description: "hidden surface preview emitted from tick")
        var emittedFrames: [ChatSessionEventFrame] = []
        var didFulfillEmittedFrame = false
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                emittedFrames.append(frame)
                if !didFulfillEmittedFrame {
                    didFulfillEmittedFrame = true
                    emittedFrame.fulfill()
                }
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == surfaceID ? Self.codexRows(answer: expectedText) : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        streamer.terminalDidTick()

        await fulfillment(of: [emittedFrame], timeout: 1.0)
        guard case .streamingProse(let message?) = emittedFrames.first?.event,
              case .prose(let prose) = message.kind else {
            return XCTFail("Expected tick-driven preview")
        }
        XCTAssertEqual(prose.text, expectedText)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testRearmingSessionOnDifferentSurfaceClearsPreviousPreview() async throws {
        let originalSurfaceID = UUID()
        let reboundSurfaceID = UUID()
        let sessionID = "session-rebound-away-from-frozen-tab"
        let expectedText = "Still working on the answer."

        let emittedFrame = expectation(description: "initial streaming prose frame emitted")
        let clearedFrame = expectation(description: "stale streaming prose frame cleared")
        var emittedFrames: [ChatSessionEventFrame] = []
        var didFulfillEmittedFrame = false
        var didFulfillClearedFrame = false
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                if !didFulfillEmittedFrame {
                    didFulfillEmittedFrame = true
                    emittedFrame.fulfill()
                } else if !didFulfillClearedFrame, case .streamingProse(nil) = frame.event {
                    didFulfillClearedFrame = true
                    clearedFrame.fulfill()
                }
                emittedFrames.append(frame)
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == originalSurfaceID ? Self.codexRows(answer: expectedText) : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: originalSurfaceID, agentKind: .codex)
        streamer.surfaceDidChange(originalSurfaceID)
        await fulfillment(of: [emittedFrame], timeout: 1.0)

        streamer.turnStarted(sessionID: sessionID, surfaceID: reboundSurfaceID, agentKind: .codex)
        await fulfillment(of: [clearedFrame], timeout: 1.0)

        XCTAssertEqual(emittedFrames.count, 2)
        guard case .streamingProse(let initial?) = emittedFrames.first?.event,
              case .prose(let prose) = initial.kind else {
            return XCTFail("Expected initial preview prose")
        }
        XCTAssertEqual(prose.text, expectedText)
        guard case .streamingProse(nil) = emittedFrames.last?.event else {
            return XCTFail("Expected rebound surface to clear the old preview")
        }
        streamer.turnEnded(sessionID: sessionID)
    }

    func testStaleSnapshotResultDoesNotEmitAfterSurfaceRebind() async throws {
        let originalSurfaceID = UUID()
        let reboundSurfaceID = UUID()
        let sessionID = "session-rebound-before-snapshot-finishes"
        let originalRows = Self.codexRows(answer: "This old answer must not stream after rebind.")

        let snapshotStarted = expectation(description: "original surface snapshot started")
        let snapshotGate = SnapshotGate()
        var emittedFrames: [ChatSessionEventFrame] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in emittedFrames.append(frame) },
            snapshot: { requestedSurfaceID in
                guard requestedSurfaceID == originalSurfaceID else {
                    return nil
                }
                snapshotStarted.fulfill()
                return await snapshotGate.waitForRows()
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: originalSurfaceID, agentKind: .codex)
        streamer.surfaceDidChange(originalSurfaceID)
        await fulfillment(of: [snapshotStarted], timeout: 1.0)

        streamer.turnStarted(sessionID: sessionID, surfaceID: reboundSurfaceID, agentKind: .codex)
        await snapshotGate.resume(rows: originalRows)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(emittedFrames.isEmpty)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testStaleAuthoritativeProseTokenDoesNotClearReboundTurn() async throws {
        let originalSurfaceID = UUID()
        let reboundSurfaceID = UUID()
        let sessionID = "session-rebound-before-authoritative-prose"
        var emittedFrames: [ChatSessionEventFrame] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in emittedFrames.append(frame) },
            snapshot: { _ in nil },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        let staleToken = streamer.turnStarted(
            sessionID: sessionID,
            surfaceID: originalSurfaceID,
            agentKind: .codex
        )
        let reboundToken = streamer.turnStarted(
            sessionID: sessionID,
            surfaceID: reboundSurfaceID,
            agentKind: .codex
        )

        streamer.authoritativeProseArrived(staleToken)
        XCTAssertTrue(emittedFrames.isEmpty)
        XCTAssertTrue(streamer.hasActiveUnsettledTurns)

        streamer.authoritativeProseArrived(reboundToken)
        XCTAssertFalse(streamer.hasActiveUnsettledTurns)
        XCTAssertEqual(emittedFrames.count, 1)
        guard case .streamingProse(nil) = emittedFrames.first?.event else {
            return XCTFail("Expected the matching rebound token to clear the preview")
        }
        streamer.turnEnded(sessionID: sessionID)
    }

    private static func codexRows(answer: String) -> [String] {
        [
            "> Reply with one short sentence about blue.",
            "",
            answer,
            "",
            "Working (3s Esc to interrupt)",
            "> ",
        ]
    }
}
