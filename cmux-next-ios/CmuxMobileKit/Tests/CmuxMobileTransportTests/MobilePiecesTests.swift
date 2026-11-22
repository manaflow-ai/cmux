import Foundation
import os
import Testing
@testable import CmuxMobileTransport

/// The Swift host of the kill switch only holds Rust's answer: these pin when it asks and
/// when an answer takes effect. Every refusal is Rust's (cmux-web-pieces, cmux-mobile-link).
@Suite struct MobilePiecesTests {
    private final class Calls: Sendable {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let next = OSAllocatedUnfairLock(initialState: MobilePieces.Reading())
    }

    private func make(disk: MobilePieces.Reading, calls: Calls) -> MobilePieces {
        MobilePieces(core: MobilePieces.Core(
            load: {
                calls.loads.withLock { $0 += 1 }
                return disk
            },
            check: {
                calls.checks.withLock { $0 += 1 }
                return calls.next.withLock { $0 }
            }
        ))
    }

    private let markdownOff = MobilePieces.Reading(reads: true, off: ["markdown-web": "blank math"], serial: 3, verdict: "taken")
    private let nothingOff = MobilePieces.Reading(reads: true, off: [:], serial: 4, verdict: "taken")

    @Test func theFirstQuestionOfALaunchReadsTheDiskOnce() {
        let calls = Calls()
        let pieces = make(disk: markdownOff, calls: calls)
        #expect(calls.loads.withLock { $0 } == 0)
        #expect(pieces.isOff(.markdownWeb))
        #expect(!pieces.isOff(.terminalPredictiveEcho))
        #expect(!pieces.isOff(.terminalAgentCLIChanges))
        #expect(calls.loads.withLock { $0 } == 1)
        #expect(calls.checks.withLock { $0 } == 0)
    }

    @Test func aCheckTakesEffectOnlyWhenApplied() async {
        let calls = Calls()
        let pieces = make(disk: nothingOff, calls: calls)
        calls.next.withLock { $0 = markdownOff }
        await pieces.check()
        #expect(!pieces.isOff(.markdownWeb))
        #expect(pieces.applyChecked())
        #expect(pieces.isOff(.markdownWeb))
        // Nothing waits: applying again changes nothing.
        #expect(!pieces.applyChecked())

        // The switch is removed: the piece comes back on.
        calls.next.withLock { $0 = nothingOff }
        await pieces.check()
        #expect(pieces.isOff(.markdownWeb))
        #expect(pieces.applyChecked())
        #expect(!pieces.isOff(.markdownWeb))
    }

    /// Open screens that read a piece once (a terminal's predictive echo and Agent CLI
    /// Screen Changes, the chat's row layouts) follow a changed answer by this notification.
    @Test func aChangedAnswerIsPostedAndAnUnchangedOneIsNot() async {
        let calls = Calls()
        let pieces = make(disk: nothingOff, calls: calls)
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: MobilePieces.didChangeNotification, object: pieces, queue: nil) { _ in
            posts.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        calls.next.withLock { $0 = markdownOff }
        await pieces.check()
        #expect(posts.withLock { $0 } == 0)
        #expect(pieces.applyChecked())
        #expect(posts.withLock { $0 } == 1)
        // Nothing waits: nothing posted.
        #expect(!pieces.applyChecked())
        #expect(posts.withLock { $0 } == 1)

        // The same pieces off under a newer serial: no change, nothing posted.
        calls.next.withLock { $0 = MobilePieces.Reading(reads: true, off: ["markdown-web": "blank math"], serial: 5, verdict: "taken") }
        await pieces.check()
        #expect(!pieces.applyChecked())
        #expect(posts.withLock { $0 } == 1)

        // The switch is removed: posted again.
        calls.next.withLock { $0 = nothingOff }
        await pieces.check()
        #expect(pieces.applyChecked())
        #expect(posts.withLock { $0 } == 2)
    }

    /// The first read loads the disk outside the lock: another reader is not held behind it,
    /// and an answer applied while the load was out is not replaced by the older disk reading.
    @Test(.timeLimit(.minutes(1))) func aSlowFirstLoadNeitherBlocksNorRegressesANewerAnswer() async throws {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let next = OSAllocatedUnfairLock(initialState: markdownOff)
        let disk = nothingOff
        let pieces = MobilePieces(core: MobilePieces.Core(
            load: {
                let n = loads.withLock { $0 += 1; return $0 }
                if n == 1 {
                    started.withLock { $0 = true }
                    gate.wait()
                }
                return disk
            },
            check: { next.withLock { $0 } }
        ))

        // A first reader whose load is held on the disk.
        let slow = OSAllocatedUnfairLock<MobilePieces.Reading?>(initialState: nil)
        DispatchQueue.global().async {
            let reading = pieces.applied
            slow.withLock { $0 = reading }
        }
        for _ in 0..<2000 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(started.withLock { $0 })

        // Meanwhile another reader loads and returns (the lock is not held over the load), and
        // a check's answer is applied.
        #expect(pieces.applied == disk)
        await pieces.check()
        #expect(pieces.applyChecked())
        #expect(pieces.isOff(.markdownWeb))

        // The held load lands last with the older disk reading: the applied answer stays.
        gate.signal()
        for _ in 0..<2000 where slow.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(slow.withLock { $0 } == markdownOff)
        #expect(pieces.isOff(.markdownWeb))
        #expect(pieces.applied == markdownOff)
        #expect(loads.withLock { $0 } == 2)
    }

    @Test func aBuildThatReadsNoFileNeverChecks() async {
        let calls = Calls()
        let pieces = make(disk: MobilePieces.Reading(), calls: calls)
        calls.next.withLock { $0 = markdownOff }
        await pieces.check()
        #expect(calls.checks.withLock { $0 } == 0)
        #expect(!pieces.applyChecked())
        for piece in MobilePieces.Piece.allCases { #expect(!pieces.isOff(piece)) }
    }

    @Test func aNameThisBuildDoesNotKnowSwitchesNothing() {
        let calls = Calls()
        let disk = MobilePieces.Reading(reads: true, off: ["a-later-piece": ""], serial: 1, verdict: "taken")
        let pieces = make(disk: disk, calls: calls)
        for piece in MobilePieces.Piece.allCases { #expect(!pieces.isOff(piece)) }
    }

    @Test func thePieceNamesAreRusts() {
        #expect(MobilePieces.Piece.allCases.map(\.rawValue) == ["markdown-web", "terminal-agent-cli-changes", "terminal-predictive-echo"])
    }

    @Test func thePackageBuildWithoutRustSwitchesNothing() {
        #if !canImport(CmuxMobileLinkFFI)
        #expect(MobilePieces.Core.live.load() == MobilePieces.Reading())
        #endif
    }
}
