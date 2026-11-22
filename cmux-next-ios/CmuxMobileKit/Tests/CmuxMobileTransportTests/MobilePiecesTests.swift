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
