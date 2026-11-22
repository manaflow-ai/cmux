#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "pair-requests")

/// Another device waiting for a linked Mac's Allow, allowed from this phone (Leo, 2026-11-22:
/// "ok surely we dont need to be bottled this hard by a click. and esp on a single machine.").
/// Each Mac whose hostd lists `pair-requests-v1` is asked for its waiting pairing requests
/// (cmux-mobile-host `pair_requests.rs`); each shows as a card with the asking device's name and
/// fingerprint, and Allow or Don't Allow answers it on that Mac as the person's click there would.
///
/// What to ask, how to read the reply and when to ask again are decided in Rust
/// (cmux-mobile-link-ffi `pair_requests.rs`); this class only opens the channels and keeps the
/// cards. hostd pushes nothing when a request starts waiting, so each Mac is listed when its link
/// is served and on foreground, every few seconds while a card shows, slower for a few minutes
/// after that, then not until the next foreground or link (`pair_requests_poll_delay_ms`).
@MainActor
@Observable
public final class MacPairRequests {
    /// One waiting request on one Mac.
    public struct Card: Identifiable, Equatable, Sendable {
        public let macID: String
        public let macName: String
        public let request: PairRequestCard
        /// An answer is on its way.
        public var answering = false
        /// The Mac refused the last answer (its reason, shown on the card).
        public var error: String?

        public var id: String { "\(macID)/\(request.deviceId)/\(request.fingerprint)" }
    }

    /// The cards to show, by Mac then in the order the Mac lists them.
    public private(set) var cards: [Card] = []

    /// What a Mac's poll reads: its served link now (nil: not served), its name, and the
    /// capabilities its hostd listed (nil: not known yet).
    struct Source {
        var link: @MainActor () -> (any MacLink)?
        var name: @MainActor () -> String
        var capabilities: @MainActor () -> Set<String>?
    }

    @ObservationIgnored private var sources: [String: Source] = [:]
    @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]
    /// The last link open, foreground or shown card of each Mac: the slow poll runs for a while after it.
    @ObservationIgnored private var lastActive: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var backgrounded = false

    public init() {}

    /// `macID`'s link is served (its pairing passed): list it now and keep listing.
    func linkServed(macID: String, source: Source) {
        sources[macID] = source
        kick(macID)
    }

    /// The app came to the front: every linked Mac is listed again.
    public func foreground() {
        backgrounded = false
        for macID in sources.keys { kick(macID) }
    }

    /// The app went to the back: no more listing until the next foreground.
    public func background() {
        backgrounded = true
        for task in polls.values { task.cancel() }
        polls.removeAll()
    }

    /// Allow or Don't Allow `card` on its Mac.
    public func answer(_ card: Card, allow: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }), !cards[index].answering,
              let link = sources[card.macID]?.link() else { return }
        cards[index].answering = true
        cards[index].error = nil
        let args = pairRequestsAnswerArgs(card: card.request, allow: allow)
        // task-owner: self; one answer per tap (the card is `answering` until it ends).
        Task { [weak self] in
            let failure = await Self.answer(on: link, args: args)
            guard let self else { return }
            if let failure, let index = self.cards.firstIndex(where: { $0.id == card.id }) {
                log.info("pair-requests answer refused: \(failure, privacy: .public)")
                self.cards[index].answering = false
                self.cards[index].error = failure
            } else if failure == nil {
                self.cards.removeAll { $0.id == card.id }
            }
            self.kick(card.macID)
        }
    }

    /// Starts `macID`'s poll if it is not running, and counts now as activity.
    private func kick(_ macID: String) {
        lastActive[macID] = .now
        guard !backgrounded, polls[macID] == nil, sources[macID] != nil else { return }
        // task-owner: polls[macID]; ends on its own (Rust stop rule, link gone, unsupported) or on background().
        polls[macID] = Task { [weak self] in
            await self?.poll(macID)
            self?.polls[macID] = nil
        }
    }

    private func poll(_ macID: String) async {
        guard let source = sources[macID], let link = source.link() else { return drop(macID) }
        // The `version` reply that lists capabilities may land a moment after the link is served.
        var capabilities = source.capabilities()
        for _ in 0..<40 where capabilities == nil {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            capabilities = source.capabilities()
        }
        guard let capabilities, pairRequestsSupported(capabilities: Array(capabilities)) else { return drop(macID) }
        while !Task.isCancelled {
            guard let current = source.link(), current === link else { return drop(macID) }
            guard let listed = await Self.list(on: link) else { return drop(macID) }
            if Task.isCancelled { return }
            show(listed, macID: macID, macName: source.name())
            if !listed.isEmpty { lastActive[macID] = .now }
            let quiet = ContinuousClock.now - (lastActive[macID] ?? .now)
            let quietMs = UInt64(max(0, quiet.components.seconds)) * 1000
            guard let delay = pairRequestsPollDelayMs(shown: UInt32(listed.count), quietMs: quietMs) else { return }
            try? await Task.sleep(for: .milliseconds(Int(delay)))
        }
    }

    /// `macID`'s cards are now `listed`; a card answering or showing an error keeps that state.
    private func show(_ listed: [PairRequestCard], macID: String, macName: String) {
        let old = Dictionary(cards.filter { $0.macID == macID }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = listed.map { request -> Card in
            var card = Card(macID: macID, macName: macName, request: request)
            if let previous = old[card.id] {
                card.answering = previous.answering
                card.error = previous.error
            }
            return card
        }
        let others = cards.filter { $0.macID != macID }
        let updated = others + next
        if updated != cards { cards = updated }
    }

    private func drop(_ macID: String) {
        if cards.contains(where: { $0.macID == macID }) { cards.removeAll { $0.macID == macID } }
    }

    /// The waiting requests on `link`; nil when the Mac does not serve them (an older hostd).
    static func list(on link: any MacLink) async -> [PairRequestCard]? {
        do {
            let channel = try await link.openChannel(service: pairRequestsService(), args: pairRequestsListArgs())
            guard let reply = try await channel.receive() else {
                // Refused: an older hostd has no such service; any other refusal lists nothing now.
                return channel.closedBy?.code == "unknown_service" ? nil : []
            }
            await channel.close(code: "eof", reason: "")
            return pairRequestsParse(reply: String(decoding: reply, as: UTF8.self))
        } catch {
            log.info("pair-requests list: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Sends one answer; nil when the Mac took it, else why not.
    static func answer(on link: any MacLink, args: [String: String]) async -> String? {
        do {
            let channel = try await link.openChannel(service: pairRequestsService(), args: args)
            guard let reply = try await channel.receive() else {
                return channel.closedBy.map { $0.message.isEmpty ? $0.code : $0.message } ?? "no answer"
            }
            await channel.close(code: "eof", reason: "")
            if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
               object["ok"] as? Bool == true {
                return nil
            }
            return "no answer"
        } catch {
            return String(describing: error)
        }
    }
}
#endif
