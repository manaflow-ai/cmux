import CmuxMobileAgentChat
import Foundation

/// A chat open when the link comes up (a cold launch into a chat, a reconnect) reads its page in
/// the connection's first round trip: its `_acpmux/attach` is written right behind `initialize`
/// and the first watch page (``AcpmuxHub/bind(_:requestTimeout:until:)``), not after both
/// answered. acpmux answers a connection's requests in order and takes `initialize` before the
/// next one runs, so the attach reads as one sent later would; on a 30 ms relay that was a whole
/// round trip of the open (cmuxterm-hq optimum-ledger rows 95 and 105, ask-48f698fc26).
///
/// The one thing an attach took from `initialize` is its kinds: the sudo card's two are asked for
/// only from a Mac that serves `elevation-cards-v1`, since an older peer refuses more than 8. The
/// early attach asks for the kinds every Mac takes in `kinds` and those two in `alsoKinds`, which
/// a Mac with ``AcpmuxHub/alsoKindsCapability`` folds in (cmux-tui acpmux
/// `server/requests/also_kinds.rs`) and an older one ignores. Its page is used only when it reads
/// what a later attach would (``AcpmuxHub/earlyAttachesHold``): otherwise, and when the chat's read
/// moved on meanwhile, the chat attaches as before. Like `initialize`, the page is applied only
/// once the pairing passed and the connection is ready.
extension AcpmuxHub {
    /// acpmux takes `alsoKinds` on `_acpmux/attach` (cmux-tui acpmux `capabilities.rs`).
    static let alsoKindsCapability = "attach-also-kinds-v1"
    /// The most chats whose page is read before ready: each is up to one open's bytes in front of
    /// nothing (the list's page is ahead of them), and the rest attach once ready as before.
    static let earlyAttachLimit = 2

    /// An open chat's first read, written on `connection` before it was ready.
    struct EarlyAttach: Sendable {
        let read: AcpmuxSessionSource.CatchUpRead
        let connection: AcpmuxConnection
        let id: Int
    }

    /// Writes each open chat's coming read on `connection` (at most ``earlyAttachLimit``).
    func submitEarlyAttaches(on connection: AcpmuxConnection, timeout: Duration) async {
        dropEarlyAttaches()
        // This Mac's last `initialize` said its pages would be drained (sudo cards, no
        // `alsoKinds` fold): reading them again on every reconnect costs a whole page each.
        guard capabilities.isEmpty || earlyAttachesHold else { return }
        var written: [String: EarlyAttach] = [:]
        for source in liveSources where written.count < Self.earlyAttachLimit {
            guard let read = source.earlyRead(), written[read.sessionID] == nil else { continue }
            let params = AcpmuxSessionSource.attachParams(read, kinds: AcpmuxSessionSource.chatKinds,
                                                          alsoKinds: AcpmuxSessionSource.elevationKinds)
            guard let id = try? await connection.submit("_acpmux/attach", .object(params), timeout: timeout) else { break }
            written[read.sessionID] = EarlyAttach(read: read, connection: connection, id: id)
            source.holdForEarlyAttach()
        }
        guard self.connection === connection else {
            for early in written.values { Self.drop(early) }
            return
        }
        earlyAttaches = written
    }

    /// The early pages read what a later attach reads: this Mac asks for no sudo-card kinds, or
    /// folds in `alsoKinds`. Known once `initialize` answered.
    var earlyAttachesHold: Bool {
        !capabilities.contains(AcpmuxSessionSource.elevationCapability) || capabilities.contains(Self.alsoKindsCapability)
    }

    /// `sessionID`'s early page on the current connection, taken (nil: none, or one that no
    /// longer holds).
    func takeEarlyAttach(_ sessionID: String) -> EarlyAttach? {
        guard let early = earlyAttaches.removeValue(forKey: sessionID) else { return nil }
        guard earlyAttachesHold, early.connection === connection else {
            Self.drop(early)
            return nil
        }
        return early
    }

    /// The reply to `early` when it is `read`'s, on the current connection; nil sends the attach
    /// as before (none, another read, a failed or refused one).
    func earlyReply(_ early: EarlyAttach?, for read: AcpmuxSessionSource.CatchUpRead, timeout: Duration) async -> JSONValue? {
        guard let early else { return nil }
        guard early.read == read, early.connection === connection else {
            Self.drop(early)
            return nil
        }
        return try? await Self.reply(early.connection, early.id, "_acpmux/attach", timeout: timeout)
    }

    /// Lets every early page not taken go.
    func dropEarlyAttaches() {
        let left = earlyAttaches
        earlyAttaches = [:]
        for early in left.values { Self.drop(early) }
    }

    /// Reads `early`'s reply and lets it go, so the connection keeps no page nobody takes.
    nonisolated static func drop(_ early: EarlyAttach) {
        Task { _ = try? await early.connection.reply(to: early.id) }
    }
}
