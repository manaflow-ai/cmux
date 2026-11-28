import Foundation

/// The grants to end of chats brought back from a Cloud machine (``CloudAccessAsks``): each runs
/// `cmux link access revoke --all` until it answers ok, waiting longer after each failure. It
/// waits for its machine's link, so the revoke also deletes the read-only copies there
/// (`--socket`); a machine this app no longer has ends only this Mac's record. A chat with an
/// answer still running waits for it, and an answer that ends after its chat left the machine
/// revokes again, so a late grant never stays. A failure never fails a bring back; it is logged.
@MainActor
public final class CloudAccessRevokes {
    public struct Chat: Hashable, Sendable {
        public var machineID: String
        public var session: String

        public init(machineID: String, session: String) {
            self.machineID = machineID
            self.session = session
        }
    }

    /// The longest a failing revoke waits before its next try.
    private static let longestBackoff: Duration = .seconds(300)

    private var pending: Set<Chat> = []
    private var running: Set<Chat> = []
    /// Revoked in this run of the app: a ledger entry still marked brought back isn't revoked again.
    private var done: Set<Chat> = []
    /// Answers running per chat (``CloudAccessAsks``).
    private var answering: [Chat: Int] = [:]
    private var backoff: [Chat: (until: ContinuousClock.Instant, delay: Duration)] = [:]
    /// The first wait after a failure (the app's poll interval).
    public var firstBackoff: Duration = .seconds(3)

    public var isEmpty: Bool { pending.isEmpty }

    public init() {}

    public func add(_ chat: Chat) {
        if !done.contains(chat) { pending.insert(chat) }
    }

    /// An answer for `chat` starts: its revoke waits until it ends.
    public func answerStarted(_ chat: Chat) { answering[chat, default: 0] += 1 }

    /// An answer for `chat` ended; when the chat is no longer on its machine (`live` false), what it
    /// may have granted is revoked again.
    public func answerEnded(_ chat: Chat, live: Bool) {
        let left = (answering[chat] ?? 1) - 1
        answering[chat] = left > 0 ? left : nil
        guard !live else { return }
        done.remove(chat)
        backoff[chat] = nil
        pending.insert(chat)
    }

    /// Runs every pending revoke whose machine is reachable, one at a time per chat. `socket` answers
    /// a machine's link socket: nil when this app no longer has the machine (only this Mac's record
    /// ends), `.some(nil)` while it is disconnected (wait). `log` gets each failure.
    public func run(_ cli: CloudAccessCLI, socket socketOf: (String) async -> String??, log: (String) -> Void) async {
        for chat in pending.subtracting(running).sorted(by: { ($0.machineID, $0.session) < ($1.machineID, $1.session) }) {
            if answering[chat] != nil { continue }
            if let wait = backoff[chat], ContinuousClock.now < wait.until { continue }
            var socket: String?
            if let known = await socketOf(chat.machineID) {
                // Disconnected: wait for the link, so the copies there go too.
                guard let path = known else { continue }
                socket = path
            }
            // Another run may have taken it meanwhile, or an answer started.
            guard pending.contains(chat), !running.contains(chat), answering[chat] == nil,
                  backoff[chat].map({ ContinuousClock.now >= $0.until }) ?? true else { continue }
            running.insert(chat)
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await cli.revoke(socket: socket, machine: chat.machineID, session: chat.session)
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            running.remove(chat)
            if answer.ok {
                pending.remove(chat)
                done.insert(chat)
                backoff[chat] = nil
            } else {
                let delay = min(backoff[chat].map { $0.delay * 2 } ?? firstBackoff, Self.longestBackoff)
                backoff[chat] = (ContinuousClock.now + delay, delay)
                log("\(answer.errorCode ?? "") \(answer.error ?? "")")
            }
        }
    }
}
