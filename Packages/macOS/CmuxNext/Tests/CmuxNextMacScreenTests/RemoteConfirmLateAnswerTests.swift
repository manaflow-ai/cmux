import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextMacScreen
import CmuxNextSettings
import Testing

/// `cmux remote-host share on` asks "Share This Mac?" in cmux and waits 130 s. The dialog stays
/// up past that, so an Allow after the caller's deadline is still the person's answer and must
/// make the change. Before the fix the request's deadline cancelled the work holding the dialog:
/// a late Allow resumed into a cancelled task and sharing stayed off (Leo, 2026-11-15).
@Suite struct RemoteConfirmLateAnswerTests {
    /// A dialog the test answers when it chooses.
    nonisolated final class Dialog: Sendable {
        private let state = Mutex<(answer: Bool?, waiter: CheckedContinuation<Bool, Never>?)>((nil, nil))

        func ask() async -> Bool {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool? in
                    if let answer = state.answer { return answer }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        func answer(_ allow: Bool) {
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                state.answer = allow
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: allow)
        }
    }

    /// The change the dialog allows; it fails when its task was cancelled, as a hub request does.
    nonisolated final class Change: Sendable {
        private struct State {
            var applied = false
            var waiter: CheckedContinuation<Bool, Never>?
        }

        private let state = Mutex(State())

        func apply() throws {
            try Task.checkCancellation()
            let waiter = state.withLock { state in
                state.applied = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: true)
        }

        /// Whether the change was made within `limit` (one caller at a time).
        func applied(within limit: Duration) async -> Bool {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state -> Bool in
                    if state.applied { return true }
                    state.waiter = continuation
                    return false
                }
                if done { return continuation.resume(returning: true) }
                Task {
                    try? await Task.sleep(for: limit)
                    let late = self.state.withLock { state in
                        defer { state.waiter = nil }
                        return state.waiter
                    }
                    late?.resume(returning: false)
                }
            }
        }
    }

    @Test func allowAfterTheCallersDeadlineStillMakesTheChange() async throws {
        let dialog = Dialog()
        let change = Change()
        let work = CmuxRemoteActionEnvironment.confirmedChange(confirm: { await dialog.ask() }, apply: { try change.apply() })

        await #expect(throws: ControlError.self) {
            _ = try await ControlDeadline.shared.run(method: "remote.confirm", deadline: .now + .milliseconds(50), work)
        }
        dialog.answer(true)

        #expect(await change.applied(within: .seconds(5)))
    }

    @Test func allowBeforeTheDeadlineAnswersOk() async throws {
        let dialog = Dialog()
        let change = Change()
        dialog.answer(true)
        let work = CmuxRemoteActionEnvironment.confirmedChange(confirm: { await dialog.ask() }, apply: { try change.apply() })

        let reply = try await ControlDeadline.shared.run(method: "remote.confirm", deadline: .now + .seconds(5), work)

        #expect(reply == ["ok": true])
        #expect(await change.applied(within: .zero))
    }

    @Test func cancelDeclinesWithoutTheChange() async throws {
        let dialog = Dialog()
        let change = Change()
        dialog.answer(false)
        let work = CmuxRemoteActionEnvironment.confirmedChange(confirm: { await dialog.ask() }, apply: { try change.apply() })

        let reply = try await ControlDeadline.shared.run(method: "remote.confirm", deadline: .now + .seconds(5), work)

        #expect(reply == ["ok": false, "declined": true])
        #expect(await change.applied(within: .milliseconds(100)) == false)
    }
}
