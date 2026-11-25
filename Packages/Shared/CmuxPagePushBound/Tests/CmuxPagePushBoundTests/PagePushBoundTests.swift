import CmuxPagePushBound
import Testing

/// The bound on what the host feeds a chat page that does not drain, as CmuxNextAgentPane composes
/// it (AgentPaneTransport's ledger and ack deadline, AcpmuxPaneSocket's held stream and drop
/// episode), run on a model host: a daemon that streams 2 MB/s of records for 60 s into a visible
/// page whose main thread never runs, then the page drains, acks, and reads its gap back.
@Suite struct PagePushBoundTests {
    // MARK: The model

    /// A daemon frame: its seq and text (records), or a request with an id.
    struct Frame {
        var seq: Int
        var text: String
        var kind: Kind
        enum Kind { case chunk, prompt, permissionRecord, permissionAsk, permissionPending }
    }

    /// One `_acpmux/event` record of about 2 KB, or a prompt, a permission record, or a permission ask.
    static func frame(_ seq: Int) -> Frame {
        if seq % 97 == 0 {
            return Frame(seq: seq, text: #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"dir":"mux","kind":"user_message","msg":{"text":"go on"}}}"#, kind: .prompt)
        }
        if seq % 151 == 0 {
            return Frame(seq: seq, text: #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"kind":"permission_request","msg":{"permissionId":"p\#(seq)"}}}"#, kind: .permissionRecord)
        }
        if seq % 173 == 0 {
            return Frame(seq: seq, text: #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p\#(seq)"}}"#, kind: .permissionPending)
        }
        if seq % 211 == 0 {
            return Frame(seq: seq, text: #"{"jsonrpc":"2.0","id":\#(seq),"method":"session/request_permission","params":{"sessionId":"s","toolCall":{}}}"#, kind: .permissionAsk)
        }
        let text = String(repeating: "x", count: 2000)
        return Frame(seq: seq, text: #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"kind":"agent_message_chunk","msg":{"text":"\#(text)"}}}"#, kind: .chunk)
    }

    static func seq(of text: String) -> Int? {
        guard let range = text.firstRange(of: #""seq":"#) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// The host: the socket's held stream and drop episode, the transport's ledger and pushes.
    struct Host {
        let bounds: PageQueueBounds
        let rules = PageStreamShedding()
        var ledger: PagePushLedger
        var episode = PageShedEpisode()
        var inbox: [String] = []
        var inboxBytes = 0
        var awaitingAck = false
        var seq = 0
        var closed = false
        /// Every push the page was sent, in order (what waits in its renderer while it is stuck).
        var pushes: [[String]] = []
        var pushedBytes = 0
        var maxHeldBytes = 0
        var droppedTexts: [String] = []
        var deferredTexts: [String] = []
        let framesPerPush = 512
        let bytesPerPush = 4 << 20

        init(bounds: PageQueueBounds = PageQueueBounds(), push: PagePushLedger.Bounds = PagePushLedger.Bounds()) {
            self.bounds = bounds
            ledger = PagePushLedger(bounds: push)
        }

        var held: Bool { ledger.stalled }
        var heldFrames: Int { inbox.count + episode.deferred.count }
        var heldBytes: Int { inboxBytes + episode.deferredBytes }

        /// AcpmuxPaneSocket.arrived, then its pass's enqueue.
        mutating func arrive(_ text: String) {
            let bytes = text.utf8.count
            let full = bounds.full(frames: heldFrames, bytes: heldBytes, adding: bytes, held: held)
            switch episode.admit(sheddable: rules.sheddable(text), full: full,
                                 pastCeiling: bounds.pastCeiling(frames: heldFrames, bytes: heldBytes, adding: bytes)) {
            case .shed: droppedTexts.append(text)
            case .overflow: closed = true
            case .queue:
                if rules.transcriptRecord(text), episode.deferRecord(text, bytes: bytes) {
                    deferredTexts.append(text)
                } else {
                    inbox.append(text)
                    inboxBytes += bytes
                }
            }
            maxHeldBytes = max(maxHeldBytes, heldBytes)
            endIfCaughtUp()
        }

        /// AcpmuxPaneSocket.endSheddingIfCaughtUp and endShedding.
        mutating func endIfCaughtUp() {
            guard episode.beginEnding(caughtUp: bounds.caughtUp(frames: heldFrames, bytes: heldBytes, held: held)),
                  let ending = episode.end() else { return }
            for text in [rules.lagMarker(dropped: ending.dropped)] + ending.deferred {
                inbox.append(text)
                inboxBytes += text.utf8.count
            }
        }

        /// AgentPaneTransport.flush: one push of what waits, if the pacer may push.
        mutating func flush() {
            guard !awaitingAck, !inbox.isEmpty else { return }
            var count = 0
            var bytes = 0
            for text in inbox {
                if count > 0, count >= framesPerPush || bytes + text.utf8.count > bytesPerPush { break }
                count += 1
                bytes += text.utf8.count
            }
            let push = Array(inbox.prefix(count))
            inbox.removeFirst(count)
            inboxBytes -= bytes
            seq += 1
            pushes.append(push)
            pushedBytes += bytes
            ledger.pushed(seq: seq, bytes: bytes)
            awaitingAck = true
            endIfCaughtUp()
        }

        /// The ack deadline passed (AgentPaneTransport.finishAck(timedOut: true)).
        mutating func deadline() {
            guard awaitingAck else { return }
            if ledger.deadlinePassed() { awaitingAck = false }
        }

        /// The page acked push `seq` (AgentPaneTransport.acked).
        mutating func ack(_ seq: Int) {
            let resumed = ledger.acked(seq: seq)
            if resumed { endIfCaughtUp() }
            awaitingAck = false
        }
    }

    /// The page: applies pushes in order, its cursor is its last record's seq (direct.ts `apply`),
    /// and a `_acpmux/lagged` reads everything after the cursor it had then (`fetchMissedEvents`).
    struct Page {
        var lastSeq = 0
        var seen: Set<Int> = []
        var lagCursors: [Int] = []
        mutating func apply(_ push: [String]) {
            for text in push {
                if text.contains("_acpmux/lagged") { lagCursors.append(lastSeq); continue }
                guard let seq = PagePushBoundTests.seq(of: text) else { continue }
                seen.insert(seq)
                if text.contains(#""method":"_acpmux/event""#) { lastSeq = max(lastSeq, seq) }
            }
        }
    }

    /// 60 s at 2 MB/s (Leo's renderer grew 80-120 MB a minute), a deadline every 250 ms, a page
    /// that never acks; then it drains and acks every push, and reads back after each lag.
    static func run(_ push: PagePushLedger.Bounds) -> (host: Host, stuckPushes: Int, stuckBytes: Int, heldAtEnd: Int, page: Page, log: [Frame]) {
        var host = Host(push: push)
        var log: [Frame] = []
        let perTick = 250 // about 0.5 MB every 250 ms
        for _ in 0..<240 {
            for _ in 0..<perTick {
                let frame = frame(log.count + 1)
                log.append(frame)
                host.arrive(frame.text)
            }
            host.flush()
            host.deadline()
        }
        let stuckPushes = host.pushes.count
        let stuckBytes = host.pushedBytes
        let heldAtEnd = host.heldBytes
        // The page drains: it applies every push it was sent, acks the last, and from then on acks each.
        var page = Page()
        for push in host.pushes { page.apply(push) }
        host.ack(host.seq)
        var applied = host.pushes.count
        while !host.inbox.isEmpty {
            host.flush()
            for push in host.pushes[applied...] { page.apply(push) }
            applied = host.pushes.count
            host.ack(host.seq)
        }
        // Each lag's read: every record after its cursor, from the daemon's log.
        for cursor in page.lagCursors {
            for frame in log where frame.seq > cursor && frame.kind != .permissionAsk && frame.kind != .permissionPending { page.seen.insert(frame.seq) }
        }
        return (host, stuckPushes, stuckBytes, heldAtEnd, page, log)
    }

    // MARK: Tests

    @Test func aStuckPageIsPushedNoMoreThanTheBoundAndReadsItsGapBackWhole() {
        let bounds = PagePushLedger.Bounds()
        let before = Self.run(PagePushLedger.Bounds(maximumUnackedBytes: .max, maximumUnackedPushes: .max))
        let after = Self.run(bounds)
        print("page-push-bound: 60 s at 2 MB/s to a page that never acks:"
            + " pushed before \(before.stuckBytes) B in \(before.stuckPushes) pushes, after \(after.stuckBytes) B in \(after.stuckPushes) pushes;"
            + " host held at the end before \(before.heldAtEnd) B, after \(after.heldAtEnd) B (peak before \(before.host.maxHeldBytes) B, after \(after.host.maxHeldBytes) B)")
        // Pushes stop at the bound: past 8 MiB unacked, at most the push that crossed it.
        #expect(after.host.ledger.stalls == 1)
        #expect(after.stuckBytes <= bounds.maximumUnackedBytes + 4 << 20, "pushed \(after.stuckBytes) B to a stuck page")
        #expect(after.stuckPushes <= bounds.maximumUnackedPushes)
        #expect(before.stuckBytes > 10 * after.stuckBytes)
        // The host's queue stays within the bounds while the page is stuck.
        #expect(after.host.maxHeldBytes <= PageQueueBounds().maximumBytes + 4096)
        // Exactly one `_acpmux/lagged`, on resume.
        let markers = after.host.pushes.joined().filter { $0.contains("_acpmux/lagged") }
        #expect(markers.count == 1, "\(markers.count) lag markers")
        #expect(after.page.lagCursors.count == 1)
        // The gap read back: every record the daemon sent reached the page, live or by the read.
        let records = Set(after.log.filter { $0.kind != .permissionAsk && $0.kind != .permissionPending }.map(\.seq))
        #expect(records.subtracting(after.page.seen).isEmpty, "\(records.subtracting(after.page.seen).count) records never reached the page")
        #expect(!after.host.droppedTexts.isEmpty, "nothing was dropped: the test did not reach the bound")
        #expect(!after.host.closed)
    }

    @Test func aPromptOrAPermissionAskIsNeverDropped() {
        let after = Self.run(PagePushLedger.Bounds())
        let kept: [Frame.Kind] = [.prompt, .permissionRecord, .permissionAsk, .permissionPending]
        let kinds = Dictionary(after.log.map { ($0.text, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let dropped = after.host.droppedTexts.filter { kinds[$0].map(kept.contains) ?? false }
        #expect(dropped.isEmpty, "dropped \(dropped.count) prompts or permission asks")
        // Each reached the page as it was sent, not only through the gap read.
        let delivered = after.host.pushes.joined()
        for frame in after.log where kept.contains(frame.kind) {
            #expect(delivered.contains(frame.text), "seq \(frame.seq) (\(frame.kind)) was not delivered")
        }
        // A permission ask's notice and request are never held back behind the marker (they wake a
        // hidden pane, AcpmuxPaneSocket+PageWaits); only kept transcript records wait for it.
        #expect(!after.host.deferredTexts.isEmpty, "no kept record came during the episode")
        for text in after.host.deferredTexts {
            #expect(kinds[text] == .prompt || kinds[text] == .permissionRecord, "\(kinds[text].map { "\($0)" } ?? "?") waited for the marker")
        }
    }

    @Test func whatMayBeDropped() {
        let rules = PageStreamShedding()
        let chunk = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":4,"kind":"agent_message_chunk","msg":{}}}"#
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"acpmux":{"seq":5}}}}"#
        let list = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"s"}}"#
        #expect(rules.sheddable(chunk))
        #expect(rules.sheddable(update))
        #expect(rules.sheddable(list))
        // Never: prompts, permission asks and records, observed notices, replies, requests.
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"seq":6,"kind":"user_message"}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk"}}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"seq":7,"kind":"prompt_refused"}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"seq":8,"kind":"permission_request"}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"seq":9,"kind":"permission_decision"}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"promptId":"p"}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","id":3,"result":{}}"#))
        #expect(!rules.sheddable(#"{"jsonrpc":"2.0","method":"a\/b"}"#))
        #expect(rules.transcriptRecord(chunk) && rules.transcriptRecord(update) && !rules.transcriptRecord(list))
    }

    @Test func theLedgerStopsAtEitherBoundAndAnyAnswerResumes() {
        var bytes = PagePushLedger(bounds: .init(maximumUnackedBytes: 100, maximumUnackedPushes: 240))
        bytes.pushed(seq: 1, bytes: 60)
        let underBound = bytes.deadlinePassed()
        #expect(underBound)
        bytes.pushed(seq: 2, bytes: 60)
        let overBound = bytes.deadlinePassed()
        #expect(!overBound && bytes.stalled && bytes.stalls == 1)
        let stillOver = bytes.deadlinePassed()
        #expect(!stillOver && bytes.stalls == 1, "one stall per episode")
        let resumed = bytes.acked(seq: 1)
        #expect(resumed, "an ack of an old push resumes")
        #expect(!bytes.stalled && bytes.unacked.isEmpty)

        var pushes = PagePushLedger()
        for seq in 1...239 {
            pushes.pushed(seq: seq, bytes: 10)
            let flowing = pushes.deadlinePassed()
            #expect(flowing)
        }
        pushes.pushed(seq: 240, bytes: 10)
        let stopped = pushes.deadlinePassed()
        #expect(!stopped, "240 unacked pushes stop the host")
        let answered = pushes.pageAnswered()
        #expect(answered, "a send from the page resumes")

        var drains = PagePushLedger()
        for seq in 1...10_000 {
            drains.pushed(seq: seq, bytes: 1 << 20)
            drains.acked(seq: seq)
            #expect(drains.unacked.isEmpty)
        }
        #expect(drains.stalls == 0)
    }

    @Test func anEpisodeHoldsKeptRecordsBehindItsOneMarker() {
        var episode = PageShedEpisode()
        let heldOutside = episode.deferRecord("r0", bytes: 2)
        #expect(!heldOutside, "no episode: the record goes at once")
        let first = episode.admit(sheddable: true, full: true, pastCeiling: false)
        #expect(first == .shed(first: true))
        let next = episode.admit(sheddable: true, full: false, pastCeiling: false)
        #expect(next == .shed(first: false))
        let kept = episode.admit(sheddable: false, full: true, pastCeiling: false)
        #expect(kept == .queue)
        let pastCeiling = episode.admit(sheddable: false, full: true, pastCeiling: true)
        #expect(pastCeiling == .overflow)
        let heldPrompt = episode.deferRecord("prompt", bytes: 6)
        #expect(heldPrompt)
        let endsBehind = episode.beginEnding(caughtUp: false)
        #expect(!endsBehind)
        let endsCaughtUp = episode.beginEnding(caughtUp: true)
        #expect(endsCaughtUp)
        let endsAgain = episode.beginEnding(caughtUp: true)
        #expect(!endsAgain, "its end is queued once")
        let ending = episode.end()
        #expect(ending == PageShedEpisode.Ending(dropped: 2, deferred: ["prompt"]))
        let endingAgain = episode.end()
        #expect(endingAgain == nil && !episode.running && episode.deferredBytes == 0)
    }
}
