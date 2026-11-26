#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileNotifications
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "relay-catch-up")

/// Background catch-up from the relay's delta log (PROTOCOL.md "Relay delta catch-up",
/// `/v1/relay-cache/<mac>/catch-up`): a wake whose Mac is asleep or unreachable reads the
/// sealed deltas the Mac left on the relay, so the chats and list stay current without the
/// Mac. Leo, 2026-11-24: "the syncing can arguably happen in the background too, so deltas
/// can be sipped and maintained".
///
/// Rust (`PhoneCatchUp.relayRequest` / `relayApply`, `cmux_mobile_core::catch_up::relay`)
/// builds the request, opens each delta and moves the same cursors a Mac reply moves; Swift
/// posts the bytes and agrees ECDH with the push key, whose scalar stays in the Secure
/// Enclave. Off by default (`relayDeltaCatchupKey`, `relay.deltaCatchup`); a surface the relay
/// cut waits for the Mac's own catch-up.
enum RelayCatchUp {
    /// `relay.deltaCatchup`: off by default.
    static let enabledKey = "cmuxMobile.settings.relayDeltaCatchup"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}

/// The phone's push key as the relay viewer key: Rust asks for the ECDH secret only.
final class RelayPushKey: RelayViewerKey, @unchecked Sendable {
    private let keys: PushKeys
    private let user: String

    init(keys: PushKeys, user: String) {
        self.keys = keys
        self.user = user
    }

    func publicKey() -> Data {
        (try? keys.publicKey(user: user)) ?? Data()
    }

    func agree(peer: Data) throws -> Data {
        do {
            return try keys.agree(user: user, peer: peer)
        } catch {
            throw CatchUpError.Reply(message: "push key agreement: \(error)")
        }
    }
}

extension LiveCoordinator {
    /// One relay catch-up round for `session`'s Mac: the pushed chat first, then the recent
    /// ones (the relay's budget cuts from the end). True when an answer applied.
    @discardableResult
    func relayCatchUp(_ session: MacSession, pushChat: String?) async -> Bool {
        guard RelayCatchUp.enabled() else { return false }
        let macID = session.macID
        guard let keys = pairing?.push, let trust = keys.trust(),
              let mac = trust.macs[macID.lowercased()], let source = PushSignature.hexData(mac.identityKey)
        else { return false }
        let phone = catchUps.cursors(for: macID)
        var chats = pushChat.map { [$0] } ?? []
        for chat in session.acpmux.catchUpChats() where !chats.contains(chat.sessionID) { chats.append(chat.sessionID) }
        guard let call = phone.relayRequest(
            sourceDevice: macID, viewerDevice: identity.link, chats: chats, budgetBytes: 0) else { return false }
        let answer: RelayCatchUpAnswer
        do {
            let reply = try await api.relayCache(pathAndQuery: call.path, json: call.body)
            let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
            answer = try phone.relayApply(
                sourceDevice: macID, viewerDevice: identity.link, reply: reply,
                viewer: RelayPushKey(keys: keys, user: trust.user), sourcePublic: source, now: now)
        } catch {
            log.info("relay catch-up: \(macID, privacy: .public) \(String(describing: error), privacy: .public)")
            return false
        }
        catchUps.keep(macID)
        for cut in answer.cut {
            log.info("relay catch-up: \(macID, privacy: .public) cut \(cut.name, privacy: .public): \(cut.reason, privacy: .public)")
        }
        for delta in answer.answers {
            await session.acpmux.applyCatchUp(chatListJSON: delta.chatListJson, chats: delta.chats, cut: [])
            if delta.tree == .whole || delta.tree == .unchanged, let start = await session.workspaces.catchUpStart() {
                _ = await session.workspaces.applyCatchUp(
                    Data((delta.workspacesJson ?? "{}").utf8), unchanged: delta.tree == .unchanged,
                    coveredThrough: start.coveredThrough)
            }
        }
        // The relay drains its log through what every viewer acknowledged.
        let api = api
        for ack in answer.acks {
            Task.detached { _ = try? await api.relayCache(pathAndQuery: ack.path, json: ack.body) }
        }
        relayColdOpenReplaced(macID)
        return !answer.answers.isEmpty
    }
}
#endif
