#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation
import OSLog

/// Keys typed from the Feed (a terminal approval's Allow once, a question's answer) held until the
/// Mac has them, so a stalled or redialing link never drops one: each goes as one `send` under a
/// key made when it was typed (the Rust `cmux-composer-send` outbox, `push_keys`), and the Mac
/// types a key once, so an attempt that goes again after a reconnect writes nothing twice.
///
/// - **In order.** One queue; a later key never overtakes an earlier one, on any connection.
/// - **Held, then resent.** An attempt that gets no answer within ``attemptDeadline``, or whose
///   connection ended, goes again under its key on the connection that replaces it, until
///   ``hold`` (the keyboard's own limit, `DaemonTerminalSession.inputHoldLimit`) after the tap.
/// - **Never silent.** Past the hold, `type` throws ``notSent`` (no attempt went out) or
///   ``maybeSent`` (one did, and its answer never came), which the caller shows.
/// - **Carried across a redial.** A key is queued only on the connection the caller checked the
///   screen on. When that connection stalls or drops, every key not answered yet stays queued, in
///   typed order, and goes on the connection that replaces it (an attempt that already went out
///   goes again under its own key, so the Mac types it once). The Rust outbox decides this
///   (`ComposerOutbox.attach`); the hold bounds it, so a key is never typed late into a screen
///   the person has moved on from.
/// - **`identify` once per connection**, before the first key on it, never per key.
@MainActor
final class TerminalKeyOutbox {
    static let notSent = "keys-not-sent"
    static let maybeSent = "keys-maybe-sent"

    /// The connection serial while a daemon is attached, else nil.
    var connection: (@MainActor () -> Int?)?
    /// One request on the daemon channel of `connection` (throws when it is not current).
    /// `params` is the request's JSON object, so it crosses to the link as Sendable bytes.
    var request: (@MainActor (_ command: String, _ params: Data, _ connection: Int, _ deadline: Duration) async throws -> Data)?
    /// An attempt with no answer by then is lost and goes again.
    var attemptDeadline: Duration = .seconds(3)
    var clock: any Clock<Duration> = ContinuousClock()
    var tick: Duration = .milliseconds(50)

    private let outbox: ComposerOutbox
    private let origin = ContinuousClock.now
    private struct Waiter {
        let surface: Int
        let bytes: Data
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [UInt64: Waiter] = [:]
    /// The connection the queue is bound to (the outbox's `attach` decides what a change does).
    private var attached: Int?
    private var driver: Task<Void, Never>?
    private let log = Logger(subsystem: "com.cmuxterm.mobile", category: "terminal-key-outbox")

    init(nonce: String = "feed-\(UUID().uuidString)", hold: Duration = .seconds(DaemonTerminalSession.inputHoldLimit)) {
        outbox = ComposerOutbox(nonce: nonce, holdMs: Self.milliseconds(hold))
    }

    /// Keys still waiting for the Mac.
    var pending: Int { waiters.count }

    /// Types `bytes` into `surface` on `connection`, the one the caller checked the screen on.
    /// Returns once the Mac has them (once, however many attempts it took). Throws `no-link` when
    /// `connection` is not current (nothing queued), ``notSent`` or ``maybeSent`` past the hold.
    func type(surface: Int, bytes: Data, connection: Int) async throws {
        guard self.connection?() == connection, request != nil else {
            throw LinkError(code: "no-link", message: "Not connected to the Mac")
        }
        let seq = outbox.pushKeys(bytes: bytes, nowMs: nowMs())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiters[seq] = Waiter(surface: surface, bytes: bytes, continuation: continuation)
            if driver == nil { driver = Task { [weak self] in await self?.run() } }
        }
    }

    private func run() async {
        while true {
            finish(outbox.expire(nowMs: nowMs()))
            if waiters.isEmpty { break }
            if let current = connection?() { await drive(current) } else if attached != nil {
                // Redialing: what went out has no answer coming on that connection.
                outbox.linkLost()
            }
            try? await clock.sleep(for: tick)
        }
        driver = nil
    }

    private func drive(_ current: Int) async {
        if outbox.attach(connection: UInt64(truncatingIfNeeded: current)) {
            // A new connection: what went out goes again under its key, the rest stays queued in
            // typed order under its hold.
            attached = current
        }
        if outbox.needsIdentify() {
            guard let reply = try? await request?("identify", Data("{}".utf8), current, attemptDeadline), attached == current else { return }
            _ = outbox.setCapabilities(capabilities: DaemonTerminalSession.capabilities(reply))
        }
        guard outbox.isServed() else {
            await sendUnkeyed(current)
            return
        }
        while let next = outbox.nextRequest() {
            Task { [weak self] in await self?.attempt(next, on: current) }
        }
    }

    private func attempt(_ next: ComposerSendRequest, on current: Int) async {
        guard let waiter = waiters[next.seq],
              var params = (try? JSONSerialization.jsonObject(with: Data(next.paramsJson.utf8))) as? [String: Any] else { return }
        params["surface"] = waiter.surface
        guard let body = try? JSONSerialization.data(withJSONObject: params) else { return }
        let reply: Data
        do {
            reply = try await request?("send", body, current, attemptDeadline) ?? Data()
        } catch {
            // Only the connection the queue is on counts: an older one's attempts were requeued.
            if attached == current { settle(next.seq, .lost) }
            return
        }
        // A reply from an older connection must not settle an entry that the current connection
        // has already resent. The keyed daemon makes either attempt safe, and the current attempt
        // owns the result once the connection changes.
        guard attached == current else { return }
        let object = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if object["ok"] as? Bool == false {
            // The daemon says nothing was written, or says nothing: it may have typed it.
            settle(next.seq, object["error_delivery"] as? String == "known-not-delivered" ? .refused : .uncertain)
        } else {
            settle(next.seq, .applied)
        }
    }

    /// A daemon that takes no keys: its keys go as before (once, unkept), in order.
    private func sendUnkeyed(_ current: Int) async {
        let queued = outbox.giveUp()
        for done in queued {
            guard let waiter = waiters.removeValue(forKey: done.seq) else { continue }
            do {
                let reply = try await request?("send", (try? JSONSerialization.data(withJSONObject: ["surface": waiter.surface, "bytes": waiter.bytes.base64EncodedString()] as [String: Any])) ?? Data("{}".utf8), current, .seconds(20)) ?? Data()
                _ = try WorkspaceSync.check(reply)
                waiter.continuation.resume()
            } catch {
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func settle(_ seq: UInt64, _ answer: ComposerSendAnswer) {
        if let done = outbox.answer(seq: seq, answer: answer) { finish([done]) }
    }

    private func finish(_ dones: [ComposerSendDone]) {
        for done in dones {
            guard let waiter = waiters.removeValue(forKey: done.seq) else { continue }
            switch done.outcome {
            case .sent:
                waiter.continuation.resume()
            case .notSent:
                log.notice("typed keys \(done.seq, privacy: .public): not sent")
                waiter.continuation.resume(throwing: LinkError(code: Self.notSent, message: "Not sent. The Mac did not get it."))
            case .maybeSent:
                log.notice("typed keys \(done.seq, privacy: .public): maybe sent")
                waiter.continuation.resume(throwing: LinkError(code: Self.maybeSent, message: "May have been sent. Check the terminal."))
            }
        }
    }

    private func nowMs() -> UInt64 { Self.milliseconds(ContinuousClock.now - origin) }

    nonisolated static func milliseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(max(0, parts.seconds)) * 1000 + UInt64(max(0, parts.attoseconds) / 1_000_000_000_000_000)
    }
}
#endif
