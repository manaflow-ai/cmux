import Foundation
import XCTest

@testable import CmuxAgentChat

@MainActor
final class AgentChatProseStreamerTests: XCTestCase {
    private actor SnapshotGate {
        private enum PendingResult {
            case rows([String]?)
        }

        private var continuation: CheckedContinuation<[String]?, Never>?
        private var pendingResult: PendingResult?
        private var waitCount = 0

        func waitForRows() async -> [String]? {
            waitCount += 1
            if let pendingResult {
                self.pendingResult = nil
                switch pendingResult {
                case .rows(let rows):
                    return rows
                }
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(rows: [String]?) {
            if let continuation {
                continuation.resume(returning: rows)
                self.continuation = nil
            } else {
                pendingResult = .rows(rows)
            }
        }

        func snapshotCount() -> Int {
            waitCount
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
        let newestText = "Newest partial answer."
        let snapshotGate = SnapshotGate()
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
                return await snapshotGate.waitForRows()
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        streamer.surfaceDidChange(surfaceID)
        streamer.surfaceDidChange(surfaceID)
        await snapshotGate.resume(rows: Self.codexRows(answer: newestText))

        await fulfillment(of: [emittedFrame], timeout: 1.0)

        let snapshotCount = await snapshotGate.snapshotCount()
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

    func testSubscriberChangeReplaysUnchangedPreview() async throws {
        let surfaceID = UUID()
        let sessionID = "session-replays-preview-to-new-subscriber"
        let expectedText = "The unchanged preview should replay."
        let firstFrame = expectation(description: "initial preview emitted")
        let replayFrame = expectation(description: "unchanged preview replayed after subscription change")
        var previewTexts: [String] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                guard case .streamingProse(let message?) = frame.event,
                      case .prose(let prose) = message.kind else { return }
                previewTexts.append(prose.text)
                if previewTexts.count == 1 {
                    firstFrame.fulfill()
                } else if previewTexts.count == 2 {
                    replayFrame.fulfill()
                }
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == surfaceID ? Self.codexRows(answer: expectedText) : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        streamer.surfaceDidChange(surfaceID)
        await fulfillment(of: [firstFrame], timeout: 1.0)

        streamer.subscribersDidChange()
        await fulfillment(of: [replayFrame], timeout: 1.0)

        XCTAssertEqual(previewTexts, [expectedText, expectedText])
        streamer.turnEnded(sessionID: sessionID)
    }

    func testMissingExtractionClearsPreviousPreview() async throws {
        let surfaceID = UUID()
        let sessionID = "session-clears-preview-when-prose-disappears"
        let expectedText = "This preview should disappear."
        var currentRows = Self.codexRows(answer: expectedText)
        let previewFrame = expectation(description: "initial preview emitted")
        let clearFrame = expectation(description: "preview cleared after extraction disappears")
        var emittedFrames: [ChatSessionEventFrame] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                emittedFrames.append(frame)
                if case .streamingProse(let message?) = frame.event,
                   case .prose(let prose) = message.kind,
                   prose.text == expectedText {
                    previewFrame.fulfill()
                } else if case .streamingProse(nil) = frame.event {
                    clearFrame.fulfill()
                }
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == surfaceID ? currentRows : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        streamer.surfaceDidChange(surfaceID)
        await fulfillment(of: [previewFrame], timeout: 1.0)

        currentRows = []
        streamer.surfaceDidChange(surfaceID)
        await fulfillment(of: [clearFrame], timeout: 1.0)

        XCTAssertEqual(emittedFrames.count, 2)
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
        let reboundText = "This rebound surface owns the live preview."

        let snapshotStarted = expectation(description: "original surface snapshot started")
        let reboundFrameEmitted = expectation(description: "rebound surface preview emitted")
        let snapshotGate = SnapshotGate()
        var emittedFrames: [ChatSessionEventFrame] = []
        var didFulfillReboundFrame = false
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                emittedFrames.append(frame)
                guard !didFulfillReboundFrame,
                      case .streamingProse(let message?) = frame.event,
                      case .prose(let prose) = message.kind,
                      prose.text == reboundText else { return }
                didFulfillReboundFrame = true
                reboundFrameEmitted.fulfill()
            },
            snapshot: { requestedSurfaceID in
                if requestedSurfaceID == reboundSurfaceID {
                    return Self.codexRows(answer: reboundText)
                }
                guard requestedSurfaceID == originalSurfaceID else { return nil }
                snapshotStarted.fulfill()
                return await snapshotGate.waitForRows()
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )
        defer { streamer.stopAll() }

        streamer.turnStarted(sessionID: sessionID, surfaceID: originalSurfaceID, agentKind: .codex)
        streamer.surfaceDidChange(originalSurfaceID)
        await fulfillment(of: [snapshotStarted], timeout: 1.0)

        streamer.turnStarted(sessionID: sessionID, surfaceID: reboundSurfaceID, agentKind: .codex)
        await snapshotGate.resume(rows: originalRows)
        streamer.surfaceDidChange(reboundSurfaceID)

        await fulfillment(of: [reboundFrameEmitted], timeout: 1.0)
        XCTAssertEqual(emittedFrames.count, 1)
        guard case .streamingProse(let message?) = emittedFrames.first?.event,
              case .prose(let prose) = message.kind else {
            return XCTFail("Expected rebound preview prose")
        }
        XCTAssertEqual(prose.text, reboundText)
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
        XCTAssertTrue(emittedFrames.isEmpty)
        streamer.turnEnded(sessionID: sessionID)
    }

    func testStaleAuthoritativeProseTokenAfterEndDoesNotClearNewTurn() async throws {
        let originalSurfaceID = UUID()
        let reboundSurfaceID = UUID()
        let sessionID = "session-new-turn-after-ended-token"
        let expectedText = "The new turn owns this preview."
        var emittedFrames: [ChatSessionEventFrame] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in emittedFrames.append(frame) },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == reboundSurfaceID ? Self.codexRows(answer: expectedText) : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) }
        )

        let staleToken = streamer.turnStarted(
            sessionID: sessionID,
            surfaceID: originalSurfaceID,
            agentKind: .codex
        )
        streamer.turnEnded(sessionID: sessionID)
        let currentToken = streamer.turnStarted(
            sessionID: sessionID,
            surfaceID: reboundSurfaceID,
            agentKind: .codex
        )

        streamer.surfaceDidChange(reboundSurfaceID)
        await Task.yield()
        streamer.authoritativeProseArrived(staleToken)
        await Task.yield()

        XCTAssertTrue(streamer.hasActiveUnsettledTurns)
        XCTAssertFalse(emittedFrames.contains { frame in
            if case .streamingProse(nil) = frame.event { return true }
            return false
        })

        streamer.authoritativeProseArrived(currentToken)
        XCTAssertFalse(streamer.hasActiveUnsettledTurns)
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
