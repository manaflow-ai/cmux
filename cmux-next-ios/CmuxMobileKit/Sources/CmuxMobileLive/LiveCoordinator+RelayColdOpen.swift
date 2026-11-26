#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileNotifications
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "relay-cold-open")

extension LiveCoordinator {
    /// First paint from the relay cache (RFD 0142 R2): before `session`'s Mac answers a cold
    /// open, read the first screens the Mac left on the relay (the chat list, then the chats the
    /// phone already knows) and show them as cached, "as of" the time the relay stored them,
    /// until live state replaces them.
    ///
    /// Rust (`PhoneCatchUp.relayColdOpenCalls` / `relayColdOpen` / `relayColdOpenReplaced`) names
    /// the fetches, opens each envelope under the surface's floor and moves no cursor; Swift only
    /// GETs the bytes and renders. Behind the relay catch-up switch (`relay.deltaCatchup`, off by
    /// default); the hub takes a cold list only until its live watch is ready.
    func relayColdOpen(_ session: MacSession) async {
        guard RelayCatchUp.enabled(), !session.acpmux.isReady else { return }
        let macID = session.macID
        guard let keys = pairing?.push, let trust = keys.trust(),
              let mac = trust.macs[macID.lowercased()], let source = PushSignature.hexData(mac.identityKey)
        else { return }
        let phone = catchUps.cursors(for: macID)
        let viewer = RelayPushKey(keys: keys, user: trust.user)
        let chats = session.acpmux.catchUpChats().map(\.sessionID)
        var asOf: Date?
        for call in phone.relayColdOpenCalls(sourceDevice: macID, viewerDevice: identity.link, chats: chats) {
            guard !session.acpmux.isReady else { break }
            do {
                guard let reply = try await api.relayCacheSnapshot(pathAndQuery: call.path),
                      let opened = try phone.relayColdOpen(
                          surface: call.surface, envelope: reply.data, asOfMs: reply.cachedAtMs,
                          viewer: viewer, sourcePublic: source)
                else { continue }
                guard !session.acpmux.isReady else { break }
                let applied = await session.acpmux.applyCatchUp(
                    chatListJSON: opened.answer.chatListJson, chats: opened.answer.chats)
                if opened.answer.chatListJson != nil || !applied.isEmpty, let ms = opened.asOfMs {
                    let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                    asOf = min(asOf ?? at, at)
                }
                relayColdOpened[macID, default: [:]][opened.surface] = (opened.epoch, opened.seq)
            } catch {
                log.info("relay cold open: \(macID, privacy: .public) \(call.surface, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let asOf, !session.acpmux.isReady { feedStore.cachedAsOf = asOf }
    }

    /// Drops the "as of" once relay or Mac catch-up for `macID` holds every cold-opened surface
    /// at or past where its first screen stood.
    func relayColdOpenReplaced(_ macID: String) {
        guard let opened = relayColdOpened[macID], feedStore.cachedAsOf != nil else { return }
        let phone = catchUps.cursors(for: macID)
        guard opened.allSatisfy({ phone.relayColdOpenReplaced(surface: $0.key, epoch: $0.value.epoch, seq: $0.value.seq) })
        else { return }
        relayColdOpened[macID] = nil
        feedStore.cachedAsOf = nil
    }
}
#endif
