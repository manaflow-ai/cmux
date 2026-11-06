import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A chat start's folder copy whose machine socket does not answer, injected at the copy's seam
/// (``CloudOutdatedMachine/copy(socket:link:notConnected:relink:_:answer:update:)``) and read the way the composer
/// reports it (``CloudMoveFailure/copying(_:machine:retry:text:)``). Run 42157718918 (2026-11-06): the login install was
/// cancelled, then the copy failed because the machine socket did not answer. The composer must say the machine didn't
/// connect, in its own words, and offer Retry on the same machine; it must never show a Swift value or an OS error.
@Suite
@MainActor
struct CloudStartChatSocketFaultTests {
    private static let machine = "lease-lease_u_5aa53d2a", retry = CloudMoveRetries.Retry.move(machineID: "vm_2cf26a57190d902b071c")

    @MainActor private final class Calls { var copies = 0, updates = 0, sockets = 0, links = 0 }

    /// The pre-copy `identify` of a machine whose link was refused and came back (capture of run 42157718918, 03:49:10 to
    /// 03:49:27): `cmux link start-chat copy` answers `machine_not_answering`, typed apart from a copy that failed.
    private static var notAnswering: CloudMoveCLI.Answer {
        var answer = CloudMoveCLI.Answer(ok: false, error: "the machine did not answer identify (eof)")
        answer.errorCode = "machine_not_answering"
        return answer
    }

    /// The copy with `answers` in turn (the last repeats) and a link whose handshake changes after the first copy.
    private func copied(_ answers: [CloudMoveCLI.Answer], calls: Calls) async throws -> CloudMoveCLI.Answer {
        try await CloudOutdatedMachine.copy(socket: { "/tmp/cmux-link-\(calls.links).sock" }, link: { "link-\(calls.links)" },
                                            notConnected: CloudMoveFailure(message: CloudMoveStrings.notConnected(Self.machine)), relink: .zero) { _ in
            defer { calls.copies += 1; calls.links += 1 }
            return answers[min(calls.copies, answers.count - 1)]
        } answer: { ($0.ok, $0.errorCode, $0.side) } update: { calls.updates += 1; return true }
    }

    /// The copy as the start runs it, with each fault injected: `sockets` answers each socket read in turn (nil: no answer).
    private func copy(sockets: [String?], first: CloudMoveCLI.Answer = CloudMoveCLI.Answer(ok: true),
                      copyThrows: (any Error)? = nil, calls: Calls) async -> CloudMoveFailure? {
        do {
            _ = try await CloudOutdatedMachine.copy(socket: {
                defer { calls.sockets += 1 }
                return calls.sockets < sockets.count ? sockets[calls.sockets] : nil
            }, link: { "link-\(calls.updates)" }, notConnected: CloudMoveFailure(message: CloudMoveStrings.notConnected(Self.machine)),
               relink: .zero) { _ in
                calls.copies += 1
                if let copyThrows { throw copyThrows }
                return first
            } answer: { ($0.ok, $0.errorCode, $0.side) } update: { calls.updates += 1; return true }
            return nil
        } catch {
            return CloudMoveFailure.copying(error, machine: Self.machine, retry: Self.retry, text: CloudStrings.errorText)
        }
    }

    private func expectPlain(_ failure: CloudMoveFailure?) throws {
        let failure = try #require(failure)
        #expect(failure.message == CloudMoveStrings.notConnected(Self.machine), "\(failure.message)")
        for raw in ["CloudMoveFailure(", "retry:", "os error", "No such file"] { #expect(!failure.message.contains(raw), "\(raw)") }
        #expect(failure.retry == Self.retry, "Retry runs the start again on the same machine")
    }

    @Test func noSocketAnswerBeforeTheCopySaysTheMachineDidNotConnectAndOffersRetry() async throws {
        let calls = Calls()
        try expectPlain(await copy(sockets: [nil], calls: calls))
        #expect(calls.copies == 0 && calls.updates == 0, "nothing is copied to a machine that did not answer")
    }

    @Test func noSocketAnswerAfterTheUpdateSaysTheSame() async throws {
        let calls = Calls()
        var outdated = CloudMoveCLI.Answer(ok: false)
        outdated.errorCode = CloudOutdatedMachine.code
        try expectPlain(await copy(sockets: ["/tmp/cmux-link-a.sock", nil], first: outdated, calls: calls))
        #expect(calls.copies == 1 && calls.updates == 1, "copied once, updated once, never copied on a socket that is gone")
    }

    @Test func aCopyTheSocketNeverAnswersKeepsItsOwnWordsAndRetry() async throws {
        let calls = Calls()
        let failure = try #require(await copy(sockets: ["/tmp/cmux-link-a.sock"], copyThrows: ActionFailure(message: "The copy timed out."), calls: calls))
        #expect(failure.message == CloudMoveStrings.syncFailed(Self.machine, "The copy timed out."))
        #expect(failure.retry == Self.retry)
        // The folder is still on this Mac, so this is the copy's failure, never "the folder is gone".
        #expect(await CloudStartFolderGone.or(failure, root: NSTemporaryDirectory(), folder: "app") is CloudMoveFailure)
    }

    /// The link comes back just before `identify`: the copy, and only the copy, runs once more on the new link. Nothing else is sent
    /// again, and no update runs (the machine was not refused as outdated).
    @Test func aMachineThatDidNotAnswerIdentifyIsCopiedOnceMoreWhenItsLinkComesBack() async throws {
        let calls = Calls()
        let answer = try await copied([Self.notAnswering, CloudMoveCLI.Answer(ok: true)], calls: calls)
        #expect(answer.ok)
        #expect(calls.copies == 2 && calls.updates == 0)
    }

    @Test func aMachineStillNotAnsweringAfterItsOneMoreCopySaysItDidNotConnectWithRetry() async throws {
        let calls = Calls()
        let answer = try await copied([Self.notAnswering], calls: calls)
        #expect(calls.copies == 2, "one more copy, never a third")
        let failure = CloudMove.failure(syncing: answer, machine: Self.machine, retry: Self.retry)
        #expect(failure.message == CloudMoveStrings.notConnected(Self.machine), "\(failure.message)")
        #expect(failure.retry == Self.retry)
    }

    @Test func aCopyThatFailedOnAnAnsweringMachineIsNotCopiedAgain() async throws {
        let calls = Calls()
        var failed = CloudMoveCLI.Answer(ok: false, error: "fs.failure")
        failed.errorCode = "sync_failed"
        #expect(try await !copied([failed, CloudMoveCLI.Answer(ok: true)], calls: calls).ok)
        #expect(calls.copies == 1)
    }
}
