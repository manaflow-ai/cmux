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
        /// The Mac did not take the last answer (the card says so, localized, and offers it again).
        public var failed = false

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

    /// A running poll or answer, with the token that tells it apart from its replacement.
    private struct Owned {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// How long one channel open or reply may take before it is given up (a Mac that leaves a
    /// channel open without replying would otherwise hold a poll or an answer forever).
    static let replyDeadline: Duration = .seconds(10)

    @ObservationIgnored private var sources: [String: Source] = [:]
    @ObservationIgnored private var polls: [String: Owned] = [:]
    /// Answers in flight, by card id; cancelled with their Mac's link.
    @ObservationIgnored private var answers: [String: Owned] = [:]
    /// The last link open, foreground or shown card of each Mac: the slow poll runs for a while after it.
    @ObservationIgnored private var lastActive: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var backgrounded = false

    public init() {}

    /// `macID`'s link is served (its pairing passed): list it now and keep listing. A poll still
    /// running for the link this replaces is cancelled, so the new link is always listed.
    func linkServed(macID: String, source: Source) {
        sources[macID] = source
        stop(macID)
        kick(macID)
    }

    /// `macID`'s hostd said what it serves (its `version` reply): the signal a poll that found
    /// no capabilities yet waits for.
    func capabilitiesKnown(macID: String) {
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
        for poll in polls.values { poll.task.cancel() }
        polls.removeAll()
    }

    /// Allow or Don't Allow `card` on its Mac.
    public func answer(_ card: Card, allow: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }), !cards[index].answering,
              answers[card.id] == nil, let link = sources[card.macID]?.link() else { return }
        cards[index].answering = true
        cards[index].failed = false
        let args = pairRequestsAnswerArgs(card: card.request, allow: allow)
        let token = UUID()
        // task-owner: answers[card.id]; ends with its reply, its deadline, or its Mac's link (stop/drop).
        let task = Task { [weak self] in
            let took = await Self.answer(on: link, args: args)
            guard let self, !Task.isCancelled else { return }
            if self.answers[card.id]?.token == token { self.answers[card.id] = nil }
            // A link replaced while the answer was out: the new link's poll shows what the Mac has now.
            guard let current = self.sources[card.macID]?.link(), current === link else { return }
            if took {
                self.cards.removeAll { $0.id == card.id }
            } else if let index = self.cards.firstIndex(where: { $0.id == card.id }) {
                self.cards[index].answering = false
                self.cards[index].failed = true
            }
            self.kick(card.macID)
        }
        answers[card.id] = Owned(token: token, task: task)
    }

    /// Starts `macID`'s poll if it is not running, and counts now as activity.
    private func kick(_ macID: String) {
        lastActive[macID] = .now
        guard !backgrounded, polls[macID] == nil, sources[macID] != nil else { return }
        let token = UUID()
        // task-owner: polls[macID]; ends on its own (Rust stop rule, link gone, unsupported) or on stop/background.
        let task = Task { [weak self] in
            await self?.poll(macID)
            // Only this poll's own entry: a replacement started after a cancel keeps its handle.
            if self?.polls[macID]?.token == token { self?.polls[macID] = nil }
        }
        polls[macID] = Owned(token: token, task: task)
    }

    /// Cancels `macID`'s poll and its answers in flight (its link went or was replaced).
    private func stop(_ macID: String) {
        polls.removeValue(forKey: macID)?.task.cancel()
        for (id, owned) in answers where id.hasPrefix("\(macID)/") {
            owned.task.cancel()
            answers[id] = nil
        }
        if cards.contains(where: { $0.macID == macID && $0.answering }) {
            for index in cards.indices where cards[index].macID == macID { cards[index].answering = false }
        }
    }

    private func poll(_ macID: String) async {
        guard let source = sources[macID], let link = source.link() else { return drop(macID) }
        // Not known yet: `capabilitiesKnown` starts the poll again when the `version` reply lands.
        guard let capabilities = source.capabilities() else { return }
        guard pairRequestsSupported(capabilities: Array(capabilities)) else { return drop(macID) }
        while !Task.isCancelled {
            guard let current = source.link(), current === link else { return drop(macID) }
            guard let listed = await Self.list(on: link) else { return drop(macID) }
            if Task.isCancelled { return }
            show(listed, macID: macID, macName: source.name())
            if !listed.isEmpty { lastActive[macID] = .now }
            let quiet = ContinuousClock.now - (lastActive[macID] ?? .now)
            let quietMs = UInt64(max(0, quiet.components.seconds)) * 1000
            guard let delay = pairRequestsPollDelayMs(shown: UInt32(listed.count), quietMs: quietMs) else { return }
            // The poll interval itself (Rust's rule), not a readiness wait; cancellation ends it.
            try? await Task.sleep(for: .milliseconds(Int(delay)))
        }
    }

    /// `macID`'s cards are now `listed`; a card answering or showing a failure keeps that state.
    private func show(_ listed: [PairRequestCard], macID: String, macName: String) {
        let old = Dictionary(cards.filter { $0.macID == macID }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = listed.map { request -> Card in
            var card = Card(macID: macID, macName: macName, request: request)
            if let previous = old[card.id] {
                card.answering = previous.answering
                card.failed = previous.failed
            }
            return card
        }
        let others = cards.filter { $0.macID != macID }
        let updated = others + next
        if updated != cards { cards = updated }
    }

    private func drop(_ macID: String) {
        for (id, owned) in answers where id.hasPrefix("\(macID)/") {
            owned.task.cancel()
            answers[id] = nil
        }
        if cards.contains(where: { $0.macID == macID }) { cards.removeAll { $0.macID == macID } }
    }

    /// Opens one `pair-requests` channel and reads its one reply, each within `replyDeadline`;
    /// a reply that never comes closes the channel. nil reply: the Mac refused (see `closedBy`).
    static func exchange(on link: any MacLink, args: [String: String]) async throws -> (Data?, LinkError?) {
        let channel = try await LinkDeadline.run(
            timeout: replyDeadline,
            operation: { try await link.openChannel(service: pairRequestsService(), args: args) },
            onDiscard: { await $0.close(code: "eof", reason: "pair-requests expired") }
        )
        let reply: Data?
        do {
            reply = try await LinkDeadline.run(
                timeout: replyDeadline,
                operation: { try await channel.receive() },
                onCancel: { await channel.close(code: "eof", reason: "pair-requests expired") }
            )
        } catch {
            await channel.close(code: "eof", reason: "pair-requests expired")
            throw error
        }
        if reply != nil { await channel.close(code: "eof", reason: "") }
        return (reply, channel.closedBy)
    }

    /// The waiting requests on `link`; nil when the Mac does not serve them (an older hostd).
    static func list(on link: any MacLink) async -> [PairRequestCard]? {
        do {
            let (reply, closedBy) = try await exchange(on: link, args: pairRequestsListArgs())
            // Refused: an older hostd has no such service; any other refusal lists nothing now.
            guard let reply else { return closedBy?.code == "unknown_service" ? nil : [] }
            return pairRequestsParse(reply: String(decoding: reply, as: UTF8.self))
        } catch {
            log.info("pair-requests list: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Sends one answer; true when the Mac took it.
    static func answer(on link: any MacLink, args: [String: String]) async -> Bool {
        do {
            let (reply, closedBy) = try await exchange(on: link, args: args)
            guard let reply else {
                log.info("pair-requests answer refused: \(closedBy?.code ?? "closed", privacy: .public)")
                return false
            }
            let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
            return object?["ok"] as? Bool == true
        } catch {
            log.info("pair-requests answer: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
#endif
