import CmuxAgentQuestion
import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed")

/// Terminal agents in the Feed: Codex, Claude Code and other programs that
/// run in a Mac terminal tab report through the daemon's notification ledger
/// (agent hooks post "Codex finished", "Codex needs approval"; OSC 9/777/99
/// and `cmux notify` post too), not through acpmux. The Mac's own
/// notifications panel reads the same ledger (`list-notifications`) and marks
/// it read per tab (`ack-tab-notifications`).
///
/// Each notification on a terminal tab becomes one Feed item. The ledger is
/// read on connect (history) and again whenever the daemon posts a
/// notification or a tab's unread marker changes (live, and the Mac's reads).
/// Agent chat tabs are left to `LiveFeed`, which has their full turns.
///
/// The ledger is durable and holds only the title and body ("Claude
/// finished", "Bash"). An agent's prompt and its whole answer, or a failed
/// turn's error text, ride on the live `notification` event alone (memory
/// only on the Mac; `NotificationPost`), so the card shows what a GUI chat's
/// does: the prompt as the quote bubble and the answer as its body. A reply
/// typed on that card goes into the terminal's agent (`reply`), only while
/// that event is still the terminal's newest and its agent waits there
/// (cmux-next-ios/SECURITY.md "Feed reply to a terminal agent").
@MainActor
public final class TerminalFeed {
    /// One `list-notifications` row.
    public struct Entry: Hashable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var body: String
        public var level: String
        public var surface: Int?
        public var createdAt: Date
        public var source: String
        public var acknowledged: Bool
        /// The question a terminal agent still waits on (an AskUserQuestion in
        /// Claude Code; the daemon's `question`, while the agent is blocked on it).
        public var question: AgentQuestion?
        /// The push that names this question (`q-` and a hash of what it asks,
        /// cmux-mobile-host `question_event_id`): a notification answers only its own question.
        public var questionEventID: String?

        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            self.id = id
            title = json["title"] as? String ?? ""
            subtitle = (json["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            body = json["body"] as? String ?? ""
            level = json["level"] as? String ?? "info"
            surface = json["surface"] as? Int
            createdAt = AgentState.date(json["created_at_ms"]) ?? Date(timeIntervalSince1970: 0)
            source = json["source"] as? String ?? "cli"
            acknowledged = json["acknowledged"] as? Bool ?? false
            let raw = json["question"] as? [String: Any]
            question = raw.flatMap { question in
                surface.flatMap { AgentQuestion(terminalQuestion: question, ledgerID: id, surface: $0) }
            }
            questionEventID = raw.flatMap(Self.eventID(question:))
        }

        /// cmux-mobile-host `question_event_id`: `q-` and the 64-bit FNV-1a, in hex, of the
        /// questions' prompts and option labels (`prompt \u{1} label \u{2} label ...`,
        /// questions joined by `\u{0}`). Nil when it asks nothing.
        static func eventID(question: [String: Any]) -> String? {
            guard let questions = question["questions"] as? [[String: Any]] else { return nil }
            let text = questions.compactMap { item -> String? in
                guard let prompt = item["question"] as? String else { return nil }
                let labels = (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return prompt + "\u{1}" + labels.joined(separator: "\u{2}")
            }.joined(separator: "\u{0}")
            guard !text.isEmpty else { return nil }
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3 }
            let hex = String(hash, radix: 16)
            return "q-" + String(repeating: "0", count: 16 - hex.count) + hex
        }
    }

    /// The most ledger rows read (the daemon keeps at most 256).
    static let limit = 100
    /// A terminal's own OSC notification this close to an agent hook's on the
    /// same tab is the same event told twice (Codex does both).
    static let echoWindow: TimeInterval = 10

    let store: FeedStore
    /// Sends one request on the Mac's `daemon` channel of `connection`; nil
    /// while unbound. It throws when that channel is no longer the bound one,
    /// so a read or a read mark never crosses to another Mac or connection.
    /// Parameters are integers only (`limit`, `surface`).
    public var request: (@MainActor (_ command: String, _ params: [String: Int], _ connection: Int) async throws -> Data)?
    /// Types `bytes` into the terminal `surface` on the Mac's `daemon` channel of
    /// `connection` (`send`, as the phone's own keyboard does); nil while unbound.
    public var type: (@MainActor (_ surface: Int, _ bytes: Data, _ connection: Int) async throws -> Void)?
    /// The pause between the keys of an answer: the agent's screen redraws after each.
    var keyPause: Duration = .milliseconds(300)
    var clock: any Clock<Duration> = ContinuousClock()

    /// Pastes `text` into the terminal of `surface` and submits it with Return
    /// in one `send` on the Mac's `daemon` channel of `connection`, only while
    /// `expectForeground` is still its foreground program and its agent waits
    /// at its prompt in `session` (`expect_agent`): both checked by the daemon
    /// right before the write. Throws like `request`.
    public var send: (@MainActor (_ surface: Int, _ text: String, _ expectForeground: String, _ session: String?, _ connection: Int) async throws -> Data)?

    /// A terminal agent's texts from a live `notification` event (memory only).
    public struct Texts: Hashable, Sendable {
        public var prompt: String?
        public var message: String?
        /// The posting agent's session (a reply goes only there).
        public var session: String?

        public init(prompt: String? = nil, message: String? = nil, session: String? = nil) {
            self.prompt = prompt
            self.message = message
            self.session = session
        }
    }

    /// The daemon capability that makes a Feed reply safe (`send` `expect_agent`, `submit`).
    static let replyCapability = "send-expect-agent-v1"

    private(set) var macID = ""
    private var connection: Int?
    private var tree: DaemonTree?
    private(set) var entries: [Entry] = []
    private var markers: [Int: DaemonTree.NotificationMarker] = [:]
    /// The agent last seen in each terminal (the Mac drops it when the agent exits).
    private var harnesses: [Int: String] = [:]
    /// Each terminal's agent status at the last tree, and the terminals seen
    /// going back to work since (blocked or idle, then working): an ask there
    /// was answered.
    private var statuses: [Int: WorkspaceTab.AgentStatus?] = [:]
    /// Items the Mac reported read: marked read once, so a later Unread on the phone sticks.
    private var macRead: Set<String> = []
    /// Tabs acknowledged from the phone, by the newest notification they covered.
    private var acked: [Int: Date] = [:]
    /// Whether this connection's ledger has been read once (history merges, live inserts).
    private var hydrated = false
    /// The rows of this connection's first read: history, wherever they land.
    private var historyIDs: Set<String> = []
    private var listing = false
    private var dirty = false
    private var generation = 0
    /// The Mac has no notification ledger (an older cmux): not asked again on this connection.
    private var unsupported = false
    /// Each ledger row's texts from its live event (this Mac, this launch).
    private var texts: [String: Texts] = [:]
    private var textOrder: [String] = []
    /// Texts from events without a ledger id (an older Mac), by surface in
    /// arrival order, for the new rows of the next ledger read there only.
    private var unclaimed: [Int: [Texts]] = [:]
    /// Whether this connection's daemon checks a reply's agent (nil: not asked yet).
    private var replySupported: Bool?

    public init(store: FeedStore) {
        self.store = store
    }

    /// The item id of a ledger row on `macID`.
    static func itemID(macID: String, entry: String) -> String { "term-\(macID)-\(entry)" }

    // MARK: Inputs

    /// The Mac's tree arrived (`connection` names the daemon channel it came
    /// on): a new connection reads the ledger (history); a changed unread
    /// marker reads it again (a new notification, or a read on the Mac).
    public func treeChanged(_ tree: DaemonTree, macID: String, connection: Int) {
        if macID != self.macID {
            texts = [:]
            textOrder = []
            unclaimed = [:]
        }
        if connection != self.connection || macID != self.macID {
            unclaimed = [:]
            replySupported = nil
            self.connection = connection
            self.macID = macID
            entries = []
            markers = [:]
            harnesses = [:]
            statuses = [:]
            acked = [:]
            unsupported = false
            hydrated = false
            historyIDs = []
            generation += 1
        }
        self.tree = tree
        var resumed: Set<Int> = []
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs where tab.kind == .terminal {
                guard let surface = tree.surfaces[tab.id] else { continue }
                if let harness = tab.harness { harnesses[surface] = harness }
                // Only a change seen here counts: a first sight of "working" may predate the ask.
                // Back at work, or no longer waiting (answered, declined, or the agent quit).
                if let before = statuses[surface],
                   (before != .working && tab.agentStatus == .working) || (before == .waiting && tab.agentStatus != .waiting) {
                    resumed.insert(surface)
                }
                statuses[surface] = .some(tab.agentStatus)
            }
        }
        let changed = tree.notificationMarkers != markers
        markers = tree.notificationMarkers
        apply()
        // Back at work or no longer waiting: the asks shown on that terminal were answered there.
        // An ask that arrives later waits again.
        for entry in entries {
            guard let surface = entry.surface, resumed.contains(surface) else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            if let item = store.item(id: id), item.waitsInTerminal {
                store.resolveElsewhere(id, text: "Answered in the terminal")
            }
        }
        if !hydrated || changed { Task { await refresh() } }
    }

    /// The daemon posted a notification: keeps an agent's texts for its row, then reads the ledger.
    public func notificationPosted(_ post: NotificationPost = NotificationPost()) {
        let kept = Texts(prompt: post.prompt, message: post.message ?? post.preview, session: post.session)
        if post.source == nil || post.source == "agent", kept.prompt != nil || kept.message != nil {
            if let id = post.id {
                if texts.updateValue(kept, forKey: id) == nil { textOrder.append(id) }
                // As many as the ledger read holds, and some.
                while textOrder.count > Self.limit * 2 { texts[textOrder.removeFirst()] = nil }
            } else if let surface = post.surface {
                unclaimed[surface, default: []].append(kept)
            }
        }
        Task { await refresh() }
    }

    /// Reads the ledger now (coalesced: one read in flight, one more queued).
    public func refresh() async {
        guard request != nil, connection != nil, !unsupported else { return }
        if listing {
            dirty = true
            return
        }
        listing = true
        defer { listing = false }
        repeat {
            dirty = false
            let generation = generation
            // The connection may have changed while an earlier read ran.
            guard let request, let connection = self.connection else { return }
            do {
                let reply = try await request("list-notifications", ["limit": Self.limit], connection)
                // A newer connection queued its own read (`dirty`): go round again.
                guard generation == self.generation else { continue }
                apply(ledger: try WorkspaceSync.check(reply))
            } catch let error as DaemonReplyError {
                // An older Mac without the ledger (`notification-ack-v1`): no terminal events.
                if generation == self.generation { unsupported = true }
                log.error("list-notifications refused: \(error.message, privacy: .public)")
                return
            } catch {
                log.error("list-notifications failed: \(String(describing: error), privacy: .public)")
                return
            }
        } while dirty
    }

    /// The Mac cleared its notifications (Clear All Notifications): their
    /// terminal events leave the Feed, then the ledger is read again.
    public func cleared() {
        for entry in entries {
            let id = Self.itemID(macID: macID, entry: entry.id)
            if store.item(id: id) != nil { store.remove(id) }
        }
        entries = []
        Task { await refresh() }
    }

    func apply(ledger reply: [String: Any]) {
        let rows = ((reply["data"] as? [String: Any])?["notifications"] as? [[String: Any]]) ?? []
        entries = rows.compactMap(Entry.init(json:)).sorted { $0.createdAt < $1.createdAt }
        if !hydrated { historyIDs = Set(entries.map(\.id)) }
        apply()
        // An older Mac's texts are for this ledger read's new rows only, never a later row's
        // (a tree change between the event and this read must not drop them).
        if hydrated { unclaimed = [:] }
        hydrated = true
    }

    /// The phone read these items (opened, swiped, marked): the Mac marks
    /// their tabs read too, as its own panel does.
    public func itemsChanged(_ items: [FeedItem]) {
        guard let request, let connection, !macID.isEmpty else { return }
        let byID = Dictionary(entries.map { (Self.itemID(macID: macID, entry: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        // The Mac reads a whole tab at once, so only the read of a tab's newest
        // event marks it: reading an older one must not hide a newer one there.
        var newest: [Int: Date] = [:]
        for entry in entries where !isEcho(entry) {
            if let surface = entry.surface { newest[surface] = max(newest[surface] ?? entry.createdAt, entry.createdAt) }
        }
        var surfaces: [Int: Date] = [:]
        for item in items where item.opensTerminal && item.isRead {
            guard let entry = byID[item.id], !entry.acknowledged, let surface = entry.surface,
                  newest[surface] == entry.createdAt,
                  (acked[surface] ?? .distantPast) < entry.createdAt else { continue }
            surfaces[surface] = entry.createdAt
        }
        for (surface, newest) in surfaces {
            acked[surface] = newest
            Task {
                do {
                    _ = try WorkspaceSync.check(try await request("ack-tab-notifications", ["surface": surface], connection))
                } catch {
                    log.error("ack-tab-notifications \(surface, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Mapping

    /// Maps the ledger onto the Feed: history merges in, a row new to this
    /// connection goes on top, the Mac's reads mark items read, and a
    /// terminal waiting for input is resolved once it moved on.
    private func apply() {
        guard let tree, !macID.isEmpty else { return }
        let places = Self.places(tree)
        var history: [FeedItem] = []
        var fresh: [FeedItem] = []
        for entry in entries {
            guard let surface = entry.surface else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            let known = store.item(id: id)
            if isEcho(entry) {
                // Shown before the hook's own event arrived: the hook's tells it.
                if known != nil { store.remove(id) }
                continue
            }
            guard let place = places[surface] else { continue }
            guard place.tab.kind == .terminal else { continue }
            let harness = place.tab.harness ?? harnesses[surface] ?? Self.harness(title: entry.title) ?? "terminal"
            let isFresh = known == nil && hydrated && !historyIDs.contains(entry.id)
            // `entries` is oldest first, so an older Mac's events claim their rows in order.
            if isFresh, texts[entry.id] == nil, entry.source == "agent", let kept = unclaimed[surface]?.first {
                unclaimed[surface]?.removeFirst()
                if texts.updateValue(kept, forKey: entry.id) == nil { textOrder.append(entry.id) }
            }
            var item = Self.item(entry, id: id, harness: harness, workspace: place.workspace, tab: place.tab,
                                 texts: texts[entry.id])
            if texts[entry.id] == nil, let known, Self.isRicher(known, than: item) {
                // Shown with its texts before (this launch, or the archive): a later read of the
                // thin ledger row keeps them.
                item.kind = known.kind
                item.markdown = known.markdown
                item.quote = known.quote
            }
            if isFresh { fresh.append(item) } else {
                if let known {
                    // An answered (or declined) question card keeps what the person did.
                    if case .question(let question) = known.kind, !question.isPending || known.resolution != nil { continue }
                    // The agent moved on from a question shown inline: it was answered there.
                    if case .question = known.kind, item.kind == .needsInput {
                        store.resolveElsewhere(id, text: "Answered in the terminal")
                        continue
                    }
                    item.createdAt = known.createdAt
                    // Unchanged: no merge (each one rewrites and saves the Feed).
                    if known.kind == item.kind, known.markdown == item.markdown, known.quote == item.quote,
                       known.agentName == item.agentName,
                       known.harness == item.harness, known.workspaceID == item.workspaceID,
                       known.workspaceTitle == item.workspaceTitle, known.tabID == item.tabID { continue }
                }
                history.append(item)
            }
        }
        if !history.isEmpty { store.mergeHistory(history) }
        for item in fresh { store.upsert(item, atTop: true) }
        // The Mac's reads.
        for entry in entries where entry.acknowledged {
            let id = Self.itemID(macID: macID, entry: entry.id)
            guard !macRead.contains(id), let item = store.item(id: id) else { continue }
            macRead.insert(id)
            if !item.isRead { store.markRead(id) }
        }
        resolveWaiting()
    }

    /// A terminal that asked for input and then posted again was answered there.
    private func resolveWaiting() {
        let prefix = "term-\(macID)-"
        for entry in entries {
            guard let surface = entry.surface else { continue }
            let id = Self.itemID(macID: macID, entry: entry.id)
            guard id.hasPrefix(prefix), let item = store.item(id: id), item.waitsInTerminal else { continue }
            let later = entries.contains { $0.surface == surface && $0.createdAt > entry.createdAt && !isEcho($0) }
            if later { store.resolveElsewhere(id, text: "Answered in the terminal") }
        }
    }

    /// A terminal's own (OSC) notification next to an agent hook's on the same tab.
    private func isEcho(_ entry: Entry) -> Bool {
        guard entry.source == "terminal", let surface = entry.surface else { return false }
        return entries.contains { other in
            other.source == "agent" && other.surface == surface && abs(other.createdAt.timeIntervalSince(entry.createdAt)) <= Self.echoWindow
        }
    }

    struct Place {
        var workspace: Workspace
        var tab: WorkspaceTab
    }

    static func places(_ tree: DaemonTree) -> [Int: Place] {
        var places: [Int: Place] = [:]
        // The Mac's home workspace too: an agent there still reaches the Feed.
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs {
                if let surface = tree.surfaces[tab.id] { places[surface] = Place(workspace: workspace, tab: tab) }
            }
        }
        return places
    }

    static func item(_ entry: Entry, id: String, harness: String, workspace: Workspace, tab: WorkspaceTab,
                     texts: Texts? = nil) -> FeedItem {
        let agentName = harness == "terminal" ? "Terminal" : DaemonTree.agentName(harness)
        var kind: FeedItem.Kind = entry.question.map { .question($0) } ?? kind(entry)
        var markdown = entry.question?.items.first?.prompt ?? text(entry, agentName: agentName, kind: kind)
        if entry.question == nil, let message = texts?.message {
            switch kind {
            // The answer itself, as a GUI chat's finished turn shows it.
            case .finished: kind = .response; markdown = message
            // What went wrong, under what failed ("Reported an error: Bash").
            case .failed: markdown += "\n\n" + fenced(message)
            default: break
            }
        }
        var item = FeedItem(
            id: id, kind: kind, workspaceID: workspace.id, tabID: tab.id, agentName: agentName, harness: harness,
            workspaceTitle: workspace.title, markdown: markdown, quote: texts?.prompt.map { FeedItem.Quote($0) },
            createdAt: entry.createdAt
        )
        item.opensTerminal = true
        item.macID = workspace.macID.isEmpty ? nil : workspace.macID
        return item
    }

    /// `text` as a code block (error text is not markdown): a fence longer than any run of
    /// backticks inside it.
    static func fenced(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }

    /// `known` came with its texts (an answer, a quote) and `item` is the same row without them.
    static func isRicher(_ known: FeedItem, than item: FeedItem) -> Bool {
        switch (known.kind, item.kind) {
        case (.response, .finished): return true
        // An error with its text under the same headline, or an ask with its quote.
        case (.failed, .failed): return known.quote != nil || known.markdown.hasPrefix(item.markdown + "\n\n")
        case (.finished, .finished), (.needsInput, .needsInput): return known.quote != nil
        default: return false
        }
    }

    // MARK: Reply

    /// Types `text` into the terminal agent of `itemID` and submits it (pasted,
    /// then Return as its own key, as the Mac's reply banner does). Nil when it
    /// went in, else why not, in words for the card.
    ///
    /// Only into the waiting agent that posted the event: the event must still
    /// be its terminal's newest, the terminal must still run that agent, at its
    /// prompt (not working, not showing an approval or a question), and its
    /// foreground program must be the agent, not a shell
    /// (the daemon checks that again right before each write, so text never
    /// lands in a shell that took the terminal back).
    public func reply(itemID: String, text: String) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Type a reply first." }
        guard let request, let send, let connection, let tree, !macID.isEmpty else { return "Not connected to the Mac." }
        guard let entry = entries.first(where: { Self.itemID(macID: macID, entry: $0.id) == itemID }), let surface = entry.surface else {
            return "This event is no longer on the Mac. Open the terminal to reply."
        }
        let newest = entries.filter { $0.surface == surface && !isEcho($0) }.max { $0.createdAt < $1.createdAt }
        guard newest?.id == entry.id else { return "The agent has posted since. Reply to its newest event, or open the terminal." }
        guard let tab = Self.places(tree)[surface]?.tab, tab.kind == .terminal, let harness = tab.harness else {
            return "The agent is no longer running in that terminal."
        }
        guard let item = store.item(id: itemID), item.harness != "terminal" else { return "Open the terminal to reply." }
        guard item.harness == harness else { return "Another agent runs in that terminal now. Open it to reply." }
        // Only at the agent's prompt: text typed while it works, or into an approval or a
        // question on its screen, would answer something else.
        switch tab.agentStatus {
        case .working: return "The agent is still working. Reply when it finishes, or open the terminal."
        case .waiting: return "The agent is waiting for an answer in the terminal. Open it to answer."
        case nil: break
        }
        // The daemon checks the agent against the session that posted; without one (an older
        // Mac, or an event this launch did not see) nothing names that session.
        guard let session = texts[entry.id]?.session else {
            return "This event's agent session isn't known here. Open the terminal to reply."
        }
        var sending = false
        do {
            // The daemon must check the agent itself right before the write: the phone's view
            // of it can be a moment old. A Mac without that check gets no reply from the Feed.
            if replySupported == nil {
                let identify = try WorkspaceSync.check(try await request("identify", [:], connection))
                let data = identify["data"] as? [String: Any] ?? identify
                replySupported = (data["capabilities"] as? [String] ?? []).contains(Self.replyCapability)
            }
            guard replySupported == true else { return "Update cmux on the Mac to reply from here. Open the terminal to reply." }
            let info = try WorkspaceSync.check(try await request("process-info", ["surface": surface], connection))
            let data = info["data"] as? [String: Any] ?? info
            guard let program = Self.runningProgram(foreground: data["foreground_executable"] as? String,
                                                    command: data["command"] as? String) else {
                return "Only a shell runs in that terminal now, so the reply was not sent."
            }
            sending = true
            _ = try WorkspaceSync.check(try await send(surface, Self.typable(text), program, session, connection))
        } catch let error as DaemonReplyError {
            log.error("terminal reply refused: \(error.message, privacy: .public)")
            if error.message.contains("after the text was written") {
                return "The reply was typed but may not have been submitted. Open the terminal to check."
            }
            if error.message.contains("foreground changed") { return "The agent left that terminal, so the reply was not sent." }
            if error.message.contains("agent not waiting") {
                return "The agent is busy, asking something, or restarted. The reply was not sent. Open the terminal to reply."
            }
            return "The Mac refused the reply: \(error.message)"
        } catch {
            log.error("terminal reply failed: \(String(describing: error), privacy: .public)")
            // The send may have reached the Mac before the link dropped: say so, so it is not typed twice.
            return sending ? "The link dropped while sending. Open the terminal to check whether the reply arrived."
                : "Couldn't reach the Mac. The reply was not sent."
        }
        return nil
    }

    /// The reply as the agent's input: line breaks and tabs kept, every other
    /// control character dropped (an escape inside a paste would end it early
    /// and send the rest as keys).
    static func typable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control)
        }))
    }

    /// Interactive shells a terminal idles in (as the Mac's `process-info` reading).
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

    /// The foreground program when it is not the terminal's own shell, else nil.
    static func runningProgram(foreground: String?, command: String?) -> String? {
        func basename(_ path: String) -> String {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return name.hasPrefix("-") ? String(name.dropFirst()) : name
        }
        guard let foreground, !foreground.isEmpty else { return nil }
        let executable = basename(foreground)
        if shells.contains(executable) { return nil }
        if let command, let spawned = command.split(separator: " ").first.map({ basename(String($0)) }),
           spawned == executable, shells.contains(spawned) { return nil }
        // The daemon compares the name it reads (`foreground_executable`), as sent.
        return foreground
    }

    /// Errors fail; an approval, a question or a plan review waits for input
    /// (hooks post those as warnings; other posters are read by their words).
    static func kind(_ entry: Entry) -> FeedItem.Kind {
        if entry.level == "error" { return .failed }
        if entry.level == "warning" { return .needsInput }
        let text = "\(entry.title) \(entry.subtitle ?? "") \(entry.body)".lowercased()
        let waits = ["approval", "permission", "needs input", "needs your input", "waiting for input",
                     "waiting for your input", "asked a question", "plan review"]
        return waits.contains(where: text.contains) ? .needsInput : .finished
    }

    /// The event in words: the title without the agent's name the header
    /// already shows ("Codex needs approval" → "Needs approval"), then what
    /// it is about.
    static func text(_ entry: Entry, agentName: String, kind: FeedItem.Kind) -> String {
        var headline = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if headline.lowercased().hasPrefix(agentName.lowercased() + " ") {
            headline = String(headline.dropFirst(agentName.count + 1))
        } else if headline.caseInsensitiveCompare(agentName) == .orderedSame {
            headline = ""
        }
        if let first = headline.first { headline = first.uppercased() + headline.dropFirst() }
        let detail = [entry.subtitle, entry.body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != headline }
            .joined(separator: "\n\n")
        switch (headline.isEmpty, detail.isEmpty) {
        case (true, true): return kind == .needsInput ? "Needs your input." : kind == .failed ? "Reported an error."
            // The hook said nothing more (Codex's finished event has no body): say where (D12).
            : "Finished its turn in the terminal. Open it to see the result."
        case (false, true) where kind == .finished && ["finished", "done", "completed", "turn complete", "turn completed"]
            .contains(headline.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!"))):
            // "Codex finished" and nothing else (Codex's hook): say where to look (D12).
            return "Finished its turn in the terminal. Open it to see the result."
        case (false, true): return headline.hasSuffix(".") || headline.hasSuffix("?") || headline.hasSuffix("!") ? headline : headline + "."
        case (true, false): return detail
        case (false, false): return "**\(headline):** \(detail)"
        }
    }

    /// The agent a hook named in its title ("Codex finished" → `codex`).
    static func harness(title: String) -> String? {
        let known = ["codex", "claude", "cursor", "gemini", "opencode", "amp", "droid", "copilot", "pi"]
        guard let first = title.split(separator: " ").first?.lowercased() else { return nil }
        return known.contains(first) ? first : nil
    }
}

// MARK: Terminal agent questions

extension FeedItem {
    /// A terminal agent's ask still open on the phone: a needs-input card, or a
    /// question card nobody answered yet.
    var waitsInTerminal: Bool {
        guard resolution == nil else { return false }
        switch kind {
        case .needsInput: return true
        case .question(let question): return opensTerminal && question.isPending
        default: return false
        }
    }
}

extension TerminalFeed {
    /// Why a terminal question's answer was not typed (shown under the card; the question stays open).
    public struct QuestionRefused: Error, Equatable, Sendable {
        public var message: String
    }

    /// The question card of the agent in terminal tab `tabID` (`s<surface>`) and its question,
    /// while the agent waits on it: a push names the tab, not the ledger row.
    /// The question a push names (`eventID`, `q-<tool use id>`) when its tab still waits
    /// on it; nil for any other question, and for a push that names none (an older Mac):
    /// an old notification never answers a newer question (review B1).
    public func pendingQuestion(tabID: String, eventID: String?) -> (FeedItem, AgentQuestion)? {
        guard let eventID, eventID.hasPrefix("q-"), let tree, let surface = tree.surfaces[tabID] else { return nil }
        for entry in entries.reversed() where entry.surface == surface && entry.questionEventID == eventID {
            guard entry.question != nil, let item = store.item(id: Self.itemID(macID: macID, entry: entry.id)),
                  case .question(let question) = item.kind, question.isPending, item.resolution == nil else { continue }
            return (item, question)
        }
        return nil
    }

    /// Answers a terminal agent's question by typing it into its terminal
    /// (`TerminalQuestionKeys`), only while that terminal shows this question.
    public func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        let keys: [Data]
        do {
            keys = try TerminalQuestionKeys.keys(question, answer)
        } catch let refusal as TerminalQuestionKeys.Refusal {
            throw QuestionRefused(message: refusal.message)
        }
        try await typeOnQuestionScreen(item, question: question, answer: answer, keys: keys)
    }

    /// Declines it: Escape, on the question's screen only.
    public func decline(_ item: FeedItem, question: AgentQuestion) async throws {
        try await typeOnQuestionScreen(item, question: question, answer: AgentQuestionAnswer(selections: [:]),
                                       keys: TerminalQuestionKeys.decline)
    }

    private func typeOnQuestionScreen(_ item: FeedItem, question: AgentQuestion, answer: AgentQuestionAnswer, keys: [Data]) async throws {
        guard let request, let type, let connection, let surface = Int(question.source.session.dropFirst()),
              question.source.session.hasPrefix("s") else {
            throw QuestionRefused(message: FeedStore.notConnectedMessage)
        }
        let reply = try WorkspaceSync.check(try await request("read-screen", ["surface": surface], connection))
        let screen = (reply["data"] as? [String: Any])?["text"] as? String ?? ""
        guard TerminalQuestionKeys.screenShows(screen, question: question, answer: answer) else {
            log.info("terminal question \(item.id, privacy: .public): the terminal no longer shows it; nothing typed")
            throw QuestionRefused(message: String(localized: "The terminal isn't showing this question anymore. Nothing was typed."))
        }
        for (index, key) in keys.enumerated() {
            if index > 0 { try await clock.sleep(for: keyPause) }
            try await type(surface, key, connection)
        }
    }
}
