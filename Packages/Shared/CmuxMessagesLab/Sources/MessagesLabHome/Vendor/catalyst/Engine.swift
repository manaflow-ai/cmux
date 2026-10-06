import Foundation
import CoreGraphics

// The engine from shared/MODEL.md: one state, one reducer, a clock-driven
// scheduler, and a Responder on the other side of the chat.

struct Draft: Equatable {
    var text = ""
    var attachments: [Attachment] = []
    var replyTo: PartRef?
}

struct ConversationUIState: Equatable {
    var draft = Draft()
    var typing: [ID] = []
    var openThread: PartRef?
    /// `offset`: points scrolled up from the bottom (0 when pinned).
    var scroll = Scroll()
    struct Scroll: Equatable { var pinnedToBottom = true; var offset: CGFloat = 0 }
}

struct AppState: Equatable {
    /// `conversation.messages` holds the loaded window of the source:
    /// messages [windowStart, windowStart + count) of `total`.
    var conversation: Conversation
    var ui = ConversationUIState()
    var windowStart = 0
    var total = 0
    var atNewest: Bool { windowStart + conversation.messages.count >= total }
    static func == (a: AppState, b: AppState) -> Bool {
        a.ui == b.ui && a.windowStart == b.windowStart && a.total == b.total && a.conversation == b.conversation
    }
    var me: ID { conversation.participants.first { $0.isMe }?.id ?? "me" }
    func message(_ id: ID) -> Message? { conversation.messages.first { $0.id == id } }
}

enum Action {
    case setDraft(String)
    case send
    /// A tapback; `by` is the reacting participant (nil: me).
    case react(PartRef, Reaction.Kind, by: ID? = nil)
    case reply(PartRef)
    case closeThread
    case edit(ID, String)
    case unsend(ID)
    /// Delete… in the menu: the message leaves this device's transcript (no row stays).
    case delete(ID)
    case attach(Attachment)
    case removeDraftAttachment(ID)
    case typing(ID, Bool)
    case receive(Message)
    case status(ID, DeliveryStatus)
    /// A link preview's metadata arrived (LinkPreviews): every link part with
    /// this URL takes the title, site and image (nil keeps the current value).
    case linkMetadata(url: String, title: String?, site: String?, image: String?)
    case setScroll(offset: CGFloat, pinned: Bool)
    /// Paging: older messages decoded off the main thread.
    case prependPage([Message])
    /// Paging: newer messages below the window.
    case appendPage([Message])
    /// Drop messages far from the viewport (bounded memory).
    case evict(top: Int, bottom: Int)
    /// Jump: replace the loaded window.
    case replaceWindow([Message], start: Int)
    /// cmux: an attachment part's bytes arrived or its upload moved
    /// (HomeStore); replaces the part with the same attachment id, no motion.
    case cmuxSetAttachment(ID, Attachment)
}

enum Reducer {
    /// Pure state transition. `now` stamps new records; `newID` names them.
    static func reduce(_ s: inout AppState, _ action: Action, now: Date, newID: () -> ID) -> Message? {
        let stamp = Instant.format(now)
        switch action {
        case let .setDraft(text):
            s.ui.draft.text = text
        case .send:
            let d = s.ui.draft
            let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !d.attachments.isEmpty else { return nil }
            var parts = d.attachments.map { Part.attachment($0) }
            if !text.isEmpty { parts += TextParts.parts(for: text) }
            let m = Message(id: newID(), senderId: s.me, sentAt: stamp, parts: parts,
                            replyTo: d.replyTo ?? s.ui.openThread, status: .sending, edits: nil, retractedAt: nil, reactions: [])
            s.conversation.messages.append(m)
            s.total += 1
            s.ui.draft = Draft(text: "", attachments: [], replyTo: nil)
            s.ui.scroll = .init()
            return m
        case let .react(ref, kind, by):
            guard let i = s.conversation.messages.firstIndex(where: { $0.id == ref.messageId }) else { break }
            let actor = by ?? s.me
            var rs = s.conversation.messages[i].reactions
            let mine = rs.firstIndex { $0.senderId == actor && $0.partIndex == ref.partIndex }
            if let mine, rs[mine].kind == kind {
                rs.remove(at: mine)                          // toggle off
            } else {
                if let mine { rs.remove(at: mine) }          // one tapback per person per part
                rs.append(Reaction(senderId: actor, partIndex: ref.partIndex, kind: kind, at: stamp))
            }
            s.conversation.messages[i].reactions = rs
        case let .reply(ref):
            let root = s.message(ref.messageId)?.replyTo ?? ref      // replies store the root
            s.ui.openThread = root
            s.ui.draft.replyTo = root
        case .closeThread:
            s.ui.openThread = nil
            s.ui.draft.replyTo = nil
        case let .edit(id, text):
            guard let i = s.conversation.messages.firstIndex(where: { $0.id == id }),
                  let pi = s.conversation.messages[i].parts.firstIndex(where: { $0.plainText != nil }),
                  let old = s.conversation.messages[i].parts[pi].plainText, old != text, !text.isEmpty else { break }
            s.conversation.messages[i].edits = (s.conversation.messages[i].edits ?? []) + [.init(text: old, at: stamp)]
            s.conversation.messages[i].parts[pi] = TextParts.parts(for: text)[0]
        case let .unsend(id):
            guard let i = s.conversation.messages.firstIndex(where: { $0.id == id }) else { break }
            s.conversation.messages[i].parts = []
            s.conversation.messages[i].reactions = []
            s.conversation.messages[i].retractedAt = stamp
        case let .delete(id):
            guard let i = s.conversation.messages.firstIndex(where: { $0.id == id }) else { break }
            s.conversation.messages[i].deletedAt = stamp
            s.conversation.messages[i].reactions = []
            if s.ui.openThread?.messageId == id { s.ui.openThread = nil }
        case let .attach(a):
            s.ui.draft.attachments.append(a)
        case let .removeDraftAttachment(id):
            s.ui.draft.attachments.removeAll { $0.id == id }
        case let .typing(who, on):
            s.ui.typing.removeAll { $0 == who }
            if on { s.ui.typing.append(who) }
        case let .receive(m):
            s.ui.typing.removeAll { $0 == m.senderId }
            if s.atNewest { s.conversation.messages.append(m) }
            s.total += 1
        case let .status(id, st):
            if let i = s.conversation.messages.firstIndex(where: { $0.id == id }) { s.conversation.messages[i].status = st }
        case let .linkMetadata(url, title, site, image):
            for i in s.conversation.messages.indices {
                for (pi, p) in s.conversation.messages[i].parts.enumerated() {
                    guard case let .link(u, t, sn, img, theme) = p, u == url else { continue }
                    s.conversation.messages[i].parts[pi] = .link(url: u, title: title ?? t, siteName: site ?? sn, image: image ?? img, theme: theme)
                }
            }
        case let .setScroll(offset, pinned):
            s.ui.scroll = .init(pinnedToBottom: pinned, offset: pinned ? 0 : offset)
        case let .prependPage(page):
            s.conversation.messages.insert(contentsOf: page, at: 0)
            s.windowStart -= page.count
        case let .appendPage(page):
            s.conversation.messages.append(contentsOf: page)
        case let .evict(top, bottom):
            let n = s.conversation.messages.count
            let t = min(top, n), b = min(bottom, n - t)
            s.conversation.messages.removeFirst(t)
            s.conversation.messages.removeLast(b)
            s.windowStart += t
        case let .replaceWindow(msgs, start):
            s.conversation.messages = msgs
            s.windowStart = start
            s.ui.scroll = .init(pinnedToBottom: false, offset: 0)
        case let .cmuxSetAttachment(id, a):  // cmux
            guard let i = s.conversation.messages.firstIndex(where: { $0.id == id }),
                  let pi = s.conversation.messages[i].parts.firstIndex(where: { if case let .attachment(x) = $0 { return x.id == a.id }; return false })
            else { break }
            s.conversation.messages[i].parts[pi] = .attachment(a)
        }
        return nil
    }
}

/// Text to parts, as macOS 27 Messages sends them (lossless takes,
/// references/real-messages/interactions/link-and-text/): a line that is only
/// a URL becomes a rich link part (the card), in its place among the lines; the
/// other lines stay text bubbles, a URL inside a sentence an underlined link
/// run with no card. "URL, line break, text" is a card followed by a text
/// bubble; a bare URL is only the card. The card starts as the domain (title =
/// site = host) until LinkPreviews fills it.
enum TextParts {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static func host(_ url: URL) -> String {
        url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }
    static func linkRuns(_ text: String) -> [TextRun] {
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let url = m.url else { return nil }
            return TextRun(start: m.range.location, length: m.range.length, style: nil, link: url.absoluteString, mention: nil, detected: nil)
        }
    }
    /// The URL a line consists of (surrounding spaces allowed), else nil.
    static func soleURL(_ line: String) -> URL? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard ns.length > 0, let m = detector.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length == ns.length, let url = m.url,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
    static func parts(for text: String) -> [Part] {
        var parts: [Part] = []
        var pending: [String] = []
        func flush() {
            // Blank lines around a card do not make a bubble of their own.
            while pending.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { pending.removeFirst() }
            while pending.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { pending.removeLast() }
            guard !pending.isEmpty else { return }
            let block = pending.joined(separator: "\n")
            parts.append(.text(block, runs: linkRuns(block)))
            pending = []
        }
        for line in text.components(separatedBy: "\n") {
            if let url = soleURL(line) {
                flush()
                let h = host(url)
                parts.append(.link(url: url.absoluteString, title: h, siteName: h, image: nil, theme: "dark"))
            } else {
                pending.append(line)
            }
        }
        flush()
        return parts.isEmpty ? [.text(text, runs: linkRuns(text))] : parts
    }
}

// MARK: - Store and clock

/// Where committed message changes go (write-through; see WriteThroughSource).
protocol MessageWriter: AnyObject {
    /// A message created this session.
    func append(_ m: Message)
    /// A changed message (edit, tapback, unsend, status).
    func update(_ m: Message)
    /// The latest written copy, if this session wrote one.
    func message(_ id: ID) -> Message?
}

extension Reducer {
    /// Write the messages `action` created or changed through to `w`. Runs
    /// right after the reducer, so nothing can be evicted unwritten.
    static func writeThrough(_ action: Action, sent: Message?, state s: AppState, to w: MessageWriter) {
        switch action {
        case .send:
            if let sent { w.append(sent) }
        case let .receive(m):
            w.append(s.message(m.id) ?? m)
        case let .react(ref, _, _):
            if let m = s.message(ref.messageId) { w.update(m) }
        case let .edit(id, _), let .unsend(id), let .delete(id):
            if let m = s.message(id) { w.update(m) }
        case let .linkMetadata(url, _, _, _):
            for m in s.conversation.messages where m.parts.contains(where: { if case let .link(u, _, _, _, _) = $0 { return u == url }; return false }) { w.update(m) }
        case let .status(id, st):
            // A status can arrive after a jump moved its message out of the window.
            if let m = s.message(id) { w.update(m) } else if var m = w.message(id) { m.status = st; w.update(m) }
        default:
            break
        }
    }
}

/// Link-preview metadata for a URL (LinkPreviews.swift implements it with
/// LinkPresentation). `done` runs on the main thread once, only when metadata
/// was found; a failure or a timeout keeps the domain card.
struct LinkMetadata: Hashable { var title: String?; var site: String?; var image: String? }
protocol LinkPreviewFetching: AnyObject {
    func fetch(_ url: String, done: @escaping (LinkMetadata) -> Void)
}

protocol Responder: AnyObject {
    func start(_ store: Store)
    func didSend(_ message: Message, _ store: Store)
}

/// The store owns the state and an engine clock (seconds). Scheduled actions
/// fire when the clock advances past them; nothing sleeps.
final class Store {
    private(set) var state: AppState
    private(set) var now: Double = 0
    let baseDate: Date
    var responder: Responder?
    /// Fetches link-preview metadata for sent and received messages (once per
    /// URL, never while scrolling or paging); nil: previews keep the domain.
    var linkPreviews: LinkPreviewFetching?
    /// Receives every message change as it is committed (nil in capture).
    weak var writer: MessageWriter?
    /// (engine time, action) of every applied action, for the animator.
    var onChange: ((Action, Double, AppState, AppState) -> Void)?
    /// A scheduled reducer action, or a step that decides what to do from
    /// the state at its due time (the responder's threading decision).
    private enum Job { case action(Action), step((Store) -> Void) }
    private var queue: [(time: Double, seq: Int, job: Job)] = []
    private var seq = 0
    private var idCounter = 0

    init(conversation: Conversation, baseDate: Date, windowStart: Int = 0, total: Int? = nil) {
        state = AppState(conversation: conversation)
        state.windowStart = windowStart
        state.total = total ?? conversation.messages.count
        self.baseDate = baseDate
    }

    func date(at t: Double) -> Date { baseDate.addingTimeInterval(t) }

    func dispatch(_ action: Action) { apply(action, at: now) }

    func schedule(_ action: Action, after delay: Double) { schedule(action, at: now + delay) }

    func schedule(_ action: Action, at time: Double) { enqueue(.action(action), at: time) }

    /// Run `step` when the clock reaches `time`, in order with the scheduled
    /// actions. A step reads the state then and dispatches what it decides.
    func scheduleStep(at time: Double, _ step: @escaping (Store) -> Void) { enqueue(.step(step), at: time) }

    private func enqueue(_ job: Job, at time: Double) {
        seq += 1
        queue.append((time, seq, job))
        queue.sort { ($0.time, $0.seq) < ($1.time, $1.seq) }
    }

    /// Advance the clock, firing due actions in order.
    func advance(to t: Double) {
        while let first = queue.first, first.time <= t {
            queue.removeFirst()
            now = max(now, first.time)
            switch first.job {
            case let .action(a): apply(a, at: now)
            case let .step(f): f(self)
            }
        }
        now = max(now, t)
    }

    /// Engine time of the next scheduled action (for an event-driven wake-up).
    var nextDue: Double? { queue.first?.time }

    func makeID(_ prefix: String) -> ID { idCounter += 1; return "\(prefix)-\(idCounter)" }

    private func apply(_ action: Action, at t: Double) {
        let old = state
        let sent = Reducer.reduce(&state, action, now: date(at: t), newID: { makeID("local") })
        if let writer { Reducer.writeThrough(action, sent: sent, state: state, to: writer) }
        onChange?(action, t, old, state)
        if let sent { responder?.didSend(sent, self) }
        if let linkPreviews {
            let fresh: Message? = { if let sent { return sent }; if case let .receive(m) = action { return m }; return nil }()
            for p in fresh?.parts ?? [] {
                guard case let .link(url, title, site, image, _) = p, image == nil, title == nil || title == site else { continue }
                linkPreviews.fetch(url) { [weak self] meta in
                    self?.dispatch(.linkMetadata(url: url, title: meta.title, site: meta.site, image: meta.image))
                }
            }
        }
    }
}

// MARK: - Responder (shared/THREADS.md)

/// SplitMix64. The same seed gives the same conversation on every run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}

/// Instinct, the agent on the other side of the chat (shared/THREADS.md):
/// - My messages that arrive before it starts an answer are one turn, read
///   together. While it answers, new messages wait for the next turn.
/// - It answers inline, in a burst of 1-3 messages. Links and media follow
///   the text as their own balloons.
/// - It threads an answer only when the message it answers is no longer my
///   latest (I sent something that is not filler after it), or when I wrote
///   that message inside a thread. Decided when the answer is sent, from the
///   state then.
/// - Typing shows with timing from the answer's length, and sometimes stops
///   without a message (it hesitates) before the real answer.
/// - A task ("run", "check", "search", ...) gets a short acknowledgement now,
///   then progress and a result later. If I talked about something else in
///   between, those go into the task's thread.
/// - Filler ("ok", "thanks", an emoji) gets no answer. A message I unsend
///   before its answer is sent gets none either.
/// - Sometimes a tapback: a like or love on a short message of mine, an
///   emphasize ("!!") on good news. It replaces the acknowledgement of a
///   single statement.
/// The texts are sample conversation data, like conversation.json; they are
/// not localized.
final class DefaultResponder: Responder {
    enum Event: Equatable {
        case typing(Bool, at: Double)
        /// A message it sent: the message it answers, and the thread root (nil = inline).
        case sent(id: ID, answering: ID, thread: PartRef?, at: Double)
        /// I unsent the message before the answer went out.
        case dropped(answering: ID, at: Double)
        /// A tapback on one of my messages.
        case reacted(id: ID, tapback: String, at: Double)
    }
    /// Everything it did, in order (for tests).
    private(set) var events: [Event] = []

    enum Timing {
        static let delivered = 0.3
        static let read = 0.8
        /// Read time after my latest message, so a burst of mine is one turn.
        static let settle = 0.8
        /// How long it waits (at most twice) when I am still typing.
        static let waitForMe = 1.2
        static func typing(chars: Int) -> Double { min(4.5, 0.6 + 0.02 * Double(chars)) }
    }

    let seed: UInt64
    private var rng: SeededRandom
    private var who: ID = "instinct"
    /// The chat since start, oldest first: my messages and its answers.
    private var log: [(id: ID, mine: Bool, filler: Bool)] = []
    private var inbox: [Message] = []
    private var ready: [Answer] = []
    private var busy = false
    private var pickupGen = 0
    private var waits = 0
    private var attachmentCount = 0

    init(seed: UInt64 = 1) {
        self.seed = seed
        rng = SeededRandom(seed: seed)
    }

    func start(_ store: Store) {}

    func didSend(_ m: Message, _ store: Store) {
        who = store.state.conversation.participants.first { !$0.isMe }?.id ?? "instinct"
        let t = store.now
        store.schedule(.status(m.id, .sent), at: t)
        store.schedule(.status(m.id, .delivered(at: Instant.format(store.date(at: t + Timing.delivered)))), at: t + Timing.delivered)
        store.schedule(.status(m.id, .read(at: Instant.format(store.date(at: t + Timing.read)))), at: t + Timing.read)
        log.append((m.id, true, Self.isFiller(m)))
        inbox.append(m)
        if !busy { schedulePickup(store, after: Timing.settle) }
    }

    // MARK: Turns

    private struct Beat {
        var parts: [Part]
        /// Seconds of typing before it; nil: it follows the previous balloon at once (a link card, an upload).
        var typing: Double?
    }

    private struct Answer {
        var target: Message
        var beats: [Beat]
        var think: Double
        /// Typing that stops without a message, before the first beat: (on, off) seconds.
        var hesitate: (Double, Double)?
    }

    /// The decision for one answer, shared by its beats.
    private final class Decision { var made = false; var root: PartRef?; var dropped = false }

    private func schedulePickup(_ store: Store, after delay: Double) {
        pickupGen += 1
        let gen = pickupGen
        store.scheduleStep(at: store.now + delay) { [weak self] s in self?.pickup(s, gen: gen) }
    }

    private func pickup(_ store: Store, gen: Int) {
        guard gen == pickupGen, !busy, !inbox.isEmpty else { return }
        if !store.state.ui.draft.text.isEmpty, waits < 2 {
            waits += 1
            schedulePickup(store, after: Timing.waitForMe)
            return
        }
        waits = 0
        let turn = inbox
        inbox = []
        let reacted = react(to: turn, store)
        ready += plan(turn, store, skipAck: reacted && turn.count == 1)
        next(store)
    }

    private func next(_ store: Store) {
        guard !busy else { return }
        if !ready.isEmpty { play(ready.removeFirst(), store) }
        else if !inbox.isEmpty { schedulePickup(store, after: 0.3) }
    }

    private func play(_ a: Answer, _ store: Store) {
        busy = true
        let d = Decision()
        var t = store.now + a.think
        func typing(_ on: Bool, at time: Double) {
            store.scheduleStep(at: time) { [weak self] s in
                guard let self, !d.dropped else { return }
                s.dispatch(.typing(self.who, on))
                self.events.append(.typing(on, at: s.now))
            }
        }
        if let (on, off) = a.hesitate {
            typing(true, at: t)
            typing(false, at: t + on)
            t += on + off
        }
        for (i, beat) in a.beats.enumerated() {
            if let typed = beat.typing {
                if i > 0 { t += rng.range(0.2, 0.5) }
                typing(true, at: t)
                t += typed
            } else {
                t += rng.range(0.3, 0.7)
            }
            store.scheduleStep(at: t) { [weak self] s in self?.deliver(beat, of: a, decision: d, store: s) }
        }
        store.scheduleStep(at: t) { [weak self] s in
            self?.busy = false
            self?.next(s)
        }
    }

    private func deliver(_ beat: Beat, of a: Answer, decision d: Decision, store: Store) {
        guard !d.dropped else { return }
        if !d.made {
            d.made = true
            if let current = store.state.message(a.target.id), current.retractedAt != nil {
                d.dropped = true
                if store.state.ui.typing.contains(who) { store.dispatch(.typing(who, false)); events.append(.typing(false, at: store.now)) }
                events.append(.dropped(answering: a.target.id, at: store.now))
                return
            }
            d.root = threadRoot(for: a.target, store.state)
        }
        let m = Message(id: store.makeID("reply"), senderId: who, sentAt: Instant.format(store.date(at: store.now)),
                        parts: beat.parts, replyTo: d.root, status: nil, edits: nil, retractedAt: nil, reactions: [])
        log.append((m.id, false, false))
        store.dispatch(.receive(m))
        events.append(.sent(id: m.id, answering: a.target.id, thread: d.root, at: store.now))
    }

    /// THREADS.md, "When a reply is threaded".
    private func threadRoot(for target: Message, _ s: AppState) -> PartRef? {
        // I wrote it inside a thread: answer in that thread (a reply stores the root).
        if let root = target.replyTo { return root }
        guard let i = log.firstIndex(where: { $0.id == target.id }) else { return nil }
        let newer = log[(i + 1)...].contains { e in
            e.mine && !e.filler && s.message(e.id)?.retractedAt == nil
        }
        guard newer else { return nil }
        let part = target.parts.firstIndex { $0.plainText != nil } ?? 0
        return PartRef(messageId: target.id, partIndex: part)
    }

    // MARK: What to say

    static func isFiller(_ m: Message) -> Bool {
        guard m.parts.count == 1, let text = m.parts[0].plainText else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if fillers.contains(t) { return true }
        // Emoji only.
        return !t.isEmpty && t.unicodeScalars.allSatisfy { u in
            u.properties.isWhitespace || u.value == 0xFE0F || u.value == 0x200D || (u.properties.isEmoji && u.value > 0xFF)
        }
    }
    private static let fillers: Set<String> = ["ok", "okay", "k", "kk", "ok nice", "nice", "cool", "great", "perfect", "thanks", "thank you",
                                               "thx", "ty", "got it", "lol", "haha", "sounds good", "ok thanks", "ok cool", "np"]

    private static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return true }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        return ["what", "why", "how", "when", "where", "who", "which", "can", "could", "should", "is", "are", "do", "does", "did", "will"]
            .contains(first)
    }

    private static func has(_ text: String, _ words: [String]) -> Bool {
        let t = " " + text.lowercased() + " "
        return words.contains { t.contains($0) }
    }

    /// A tapback on the turn's last message: "!!" on good news, a like or a
    /// love on a short statement. Returns whether it will react.
    private func react(to turn: [Message], _ store: Store) -> Bool {
        guard let m = turn.last, m.parts.count == 1, let text = m.parts[0].plainText, !Self.isQuestion(text) else { return false }
        let kind: String
        if Self.isGoodNews(text) {
            guard rng.chance(0.7) else { return false }
            kind = "emphasize"
        } else if text.split(whereSeparator: \.isWhitespace).count <= 3 {
            guard rng.chance(0.5) else { return false }
            kind = rng.chance(0.6) ? "like" : "love"
        } else {
            return false
        }
        store.scheduleStep(at: store.now + rng.range(0.2, 0.9)) { [weak self] s in
            guard let self, let current = s.state.message(m.id), current.retractedAt == nil else { return }
            s.dispatch(.react(PartRef(messageId: m.id, partIndex: 0), .tapback(kind), by: self.who))
            self.events.append(.reacted(id: m.id, tapback: kind, at: s.now))
        }
        return true
    }

    static func isGoodNews(_ text: String) -> Bool {
        has(text, [" done", " fixed", " shipped", " landed", " works", " worked", " passed", " merged", " booked",
                   " approved", " green", " got the job", " we won"])
    }

    private func plan(_ turn: [Message], _ store: Store, skipAck: Bool = false) -> [Answer] {
        let meaningful = turn.filter { !Self.isFiller($0) }
        guard let last = meaningful.last else { return [] }
        let questions = meaningful.filter { m in m.parts.contains { $0.plainText.map(Self.isQuestion) ?? false } }
        // Two or more questions in one turn: one answer each (the earlier ones
        // end up threaded, because a newer question follows them).
        if questions.count >= 2 {
            // cmux: `self.` (Swift 6.2, Xcode 26.6, resolves `text` to the local below).
            return questions.prefix(3).map { q in answer(q, beats: questionBeats(self.text(of: q))) }
        }
        let all = meaningful.flatMap(\.parts)
        let text = meaningful.compactMap { m in m.parts.compactMap(\.plainText).joined(separator: " ") }.joined(separator: " ")
        if let a = all.compactMap({ p -> Attachment? in if case let .attachment(a) = p { return a } else { return nil } }).first {
            return [answer(last, beats: attachmentBeats(a, last, store))]
        }
        if all.contains(where: { if case .link = $0 { return true } else { return false } }) {
            let read = rng.pick(Lines.readLink)
            return [answer(last, beats: [Beat(parts: [.text(read, runs: [])], typing: typing(read))])]
        }
        if Self.has(text, [" run ", " rerun ", " build ", " search ", " look up ", " look into ", " find ", " check ", " deploy ",
                           " investigate ", " profile "]) {
            return [answer(last, beats: taskBeats(last, store))]
        }
        if Self.has(text, [" photo", " picture", " image", " screenshot", " pic "]) { return [answer(last, beats: imageBeats())] }
        if Self.has(text, [" pdf", " export", " csv", " report", " file "]) { return [answer(last, beats: fileBeats())] }
        if Self.has(text, [" code", " snippet", " function", " diff", " example"]) {
            return [answer(last, beats: [Beat(parts: [.text(Lines.code, runs: [])], typing: typing(Lines.code))])]
        }
        if let q = questions.first { return [answer(last, beats: questionBeats(self.text(of: q)))] }
        if skipAck { return [] }
        let ack = rng.pick(Lines.ack)
        return [answer(last, beats: [Beat(parts: [.text(ack, runs: [])], typing: typing(ack))])]
    }

    private func text(of m: Message) -> String { m.parts.compactMap(\.plainText).joined(separator: " ") }

    private func typing(_ s: String) -> Double { Timing.typing(chars: s.count) * rng.range(0.85, 1.15) }

    private func answer(_ target: Message, beats: [Beat]) -> Answer {
        let hesitate = rng.chance(0.15) ? (rng.range(0.8, 1.8), rng.range(0.6, 1.5)) : nil
        return Answer(target: target, beats: beats, think: rng.range(0.15, 0.7), hesitate: hesitate)
    }

    private func textBeats(_ s: String, splitChance: Double) -> [Beat] {
        let paragraphs = s.components(separatedBy: "\n\n")
        if paragraphs.count > 1, rng.chance(splitChance) {
            return paragraphs.prefix(3).map { Beat(parts: [.text($0, runs: [])], typing: typing($0)) }
        }
        return [Beat(parts: [.text(s, runs: [])], typing: typing(s))]
    }

    private func questionBeats(_ q: String) -> [Beat] {
        if Self.has(q, [" why", " how ", " explain", " difference", "how "]) {
            return textBeats(rng.pick(Lines.long), splitChance: 0.4)
        }
        return textBeats(rng.pick(Lines.short), splitChance: 0)
    }

    private func attachmentBeats(_ a: Attachment, _ m: Message, _ store: Store) -> [Beat] {
        let line: String
        switch a.kind {
        case "image": line = rng.pick(Lines.gotImage)
        case "video": line = "Watched it. The stutter is at 0:04, right when the second window opens."
        case "voiceMemo", "audio": line = "Listened. Yes, Thursday works, I'll move the review."
        default:
            line = "Got \(a.fileName). Reading it now."
            later(m, store, after: rng.range(7, 11), beats: textBeats(rng.pick(Lines.readFile), splitChance: 0.3))
        }
        return [Beat(parts: [.text(line, runs: [])], typing: typing(line))]
    }

    private func taskBeats(_ m: Message, _ store: Store) -> [Beat] {
        let ack = rng.pick(Lines.taskAck)
        let start = rng.range(5, 8)
        if rng.chance(0.5) { later(m, store, after: start, beats: [Beat(parts: [.text(rng.pick(Lines.progress), runs: [])], typing: 1.0)]) }
        var result = textBeats(rng.pick(Lines.result), splitChance: 0.3)
        if rng.chance(0.4) { result.append(Beat(parts: [.attachment(file("results.json", "application/json", 48_213))], typing: nil)) }
        later(m, store, after: start + rng.range(4, 7), beats: result)
        return [Beat(parts: [.text(ack, runs: [])], typing: typing(ack))]
    }

    private func imageBeats() -> [Beat] {
        attachmentCount += 1
        let image = Attachment(id: "resp-a\(attachmentCount)", kind: "image", fileName: "IMG_\(4100 + attachmentCount).jpg", mimeType: "image/jpeg",
                               byteSize: 812_344, asset: "photo-stage.jpg", poster: nil, width: 708, height: 708, durationSeconds: nil, transfer: .done)
        return [Beat(parts: [.text("Here's the one from the offsite:", runs: [])], typing: 1.0), Beat(parts: [.attachment(image)], typing: nil)]
    }

    private func fileBeats() -> [Beat] {
        [Beat(parts: [.text("Exported it.", runs: [])], typing: 0.8), Beat(parts: [.attachment(file("report.pdf", "application/pdf", 2_457_600))], typing: nil)]
    }

    private func file(_ name: String, _ mime: String, _ size: Int) -> Attachment {
        attachmentCount += 1
        return Attachment(id: "resp-a\(attachmentCount)", kind: "file", fileName: name, mimeType: mime, byteSize: size,
                          asset: nil, poster: nil, width: nil, height: nil, durationSeconds: nil, transfer: .done)
    }

    /// Work that finishes later (a task, a file to read). Its answer joins
    /// the queue when it is ready and goes out after the current answer.
    private func later(_ target: Message, _ store: Store, after delay: Double, beats: [Beat]) {
        let a = Answer(target: target, beats: beats, think: rng.range(0.1, 0.4), hesitate: nil)
        store.scheduleStep(at: store.now + delay) { [weak self] s in
            self?.ready.append(a)
            self?.next(s)
        }
    }

    private enum Lines {
        static let ack = ["Got it.", "Makes sense.", "Noted.", "Sounds good, I'll keep that in mind.", "OK, done."]
        static let short = [
            "Yes, as of this morning.",
            "Not yet. I'll tell you when it lands.",
            "Probably Thursday. The review is the slow part.",
            "No, that one is still open.",
            "About 40 minutes end to end.",
            "The second one. It's cheaper and nobody uses the extra seats.",
        ]
        static let long = [
            "Two reasons. First, the cache is keyed by width, so a resize misses every row until the new width is measured.\n\n"
                + "Second, those misses all land in one frame, because the layout asks for every visible row at once. "
                + "Measuring the next width off the main thread while the drag runs would fix both.",
            "Short version: the credits are a monthly grant, and anything you buy on top rolls over to the end of the cycle.\n\n"
                + "Longer version: the grant resets on your billing date and is used first. Bought credits only start to count "
                + "once the grant is gone, so most months you never touch them.\n\nSend me the usage page and I'll do the exact math.",
            "It goes in three steps: the draft is saved locally, the send is queued, and the server confirms.\n\n"
                + "If the network drops between the second and third step, the message stays in the queue and retries "
                + "with backoff. You only see \"Not Delivered\" after the last retry fails.",
        ]
        static let readLink = [
            "Read it. The main change is in the second half: the limit moved from per request to per day. Nothing there changes our plan.",
            "Read it. Mostly marketing, but the pricing table at the bottom is new.",
        ]
        static let gotImage = [
            "Got the screenshot. The red banner is the stale-build warning; a reload clears it.",
            "Nice. That's the new sidebar? The spacing looks right now.",
        ]
        static let readFile = [
            "Read it. Three things stand out:\n\n1. Hiring assumes four starts in July.\n2. The pricing section still uses the old tier.\n"
                + "3. There's no line for the fleet Macs.\n\nWant me to fix those in the doc?",
            "Done reading. It's fine overall; the only real gap is that the timeline has no buffer after the beta.",
        ]
        static let taskAck = ["On it.", "Running it now. Takes a few minutes.", "Looking into it.", "Starting it now."]
        static let progress = ["Halfway there, nothing unusual so far.", "Still running: 3 of 5 steps done."]
        static let result = [
            "Done. Everything passed except one flaky test, which passed on retry.",
            "Finished. Two findings:\n\n1. The slow part is the first page load, 420 ms on a cold cache.\n"
                + "2. After that every scroll frame is under 2 ms.\n\nI can open a PR for the prefetch if you want.",
            "Found it. The job failed in the notarize step, not the build: Apple's service timed out three times. "
                + "A rerun passed.",
        ]
        static let code = "Something like this:\n\nfunc prewarm(width: CGFloat) {\n    for row in visibleRows {\n"
            + "        cache.measure(row, width: width)\n    }\n}\n\nCall it from the resize handler, before the layout pass."
    }
}

/// `--responder bench` (the default with `--bench`): one inline reply to
/// every message I send, so "20 fast sends" exercises 20 inserts and 20
/// replies. Replies go out one at a time, each after its own typing
/// indicator (at least 0.5 s), as the other side of a real chat would.
/// Not a realistic counterpart otherwise (see DefaultResponder).
final class BenchResponder: Responder {
    private var cycle = 0
    private let lines = ["Got it.", "On it. I'll send what I find.", "Makes sense to me.", "Sounds good, I'll take a look."]
    private var pending = 0
    private var replying = false

    func start(_ store: Store) {}

    func didSend(_ m: Message, _ store: Store) {
        let t = store.now
        store.schedule(.status(m.id, .sent), at: t)
        store.schedule(.status(m.id, .delivered(at: Instant.format(store.date(at: t + 0.3)))), at: t + 0.3)
        store.schedule(.status(m.id, .read(at: Instant.format(store.date(at: t + 0.8)))), at: t + 0.8)
        pending += 1
        if !replying {
            replying = true
            store.scheduleStep(at: t + 0.8) { [weak self] s in self?.reply(s) }
        }
    }

    /// Typing on now, the reply after a typing time from its length, then
    /// the next pending reply 0.3 s later.
    private func reply(_ store: Store) {
        guard pending > 0 else { replying = false; return }
        pending -= 1
        let who = store.state.conversation.participants.first { !$0.isMe }?.id ?? "instinct"
        let text = lines[cycle % lines.count]
        cycle += 1
        store.dispatch(.typing(who, true))
        let typed = 0.4 + 0.025 * Double(text.count)
        store.scheduleStep(at: store.now + typed) { [weak self] s in
            let m = Message(id: s.makeID("reply"), senderId: who, sentAt: Instant.format(s.date(at: s.now)),
                            parts: [.text(text, runs: [])], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
            s.dispatch(.receive(m))
            s.scheduleStep(at: s.now + 0.3) { [weak self] s in self?.reply(s) }
        }
    }
}

enum Responders {
    /// `--responder bench|realistic`; without it, `--bench` runs use the bench
    /// responder and every other run the realistic one.
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments, seed: UInt64 = 1) -> Responder {
        let choice = arguments.firstIndex(of: "--responder").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        if choice == "bench" || choice == nil && arguments.contains("--bench") { return BenchResponder() }
        return DefaultResponder(seed: seed)
    }
}
