import CmuxAgentQuestion
import CmuxConversationCore
import Foundation
import CoreGraphics
import ImageIO

// The mock Chief is DEBUG and Demo only: never compiled into Production.
#if DEBUG
/// A local Chief for UI work and demos: a seeded history, read receipts,
/// a typing indicator while Chief "thinks", replies drawn from what was
/// asked, and tapbacks on messages that thank or praise it. The real Chief
/// is `ChiefDaemonBackend` (cmux-tui `conversation-*` over the link); both
/// sit behind `ConversationBackend`, so the screen does not change.
public final class ChiefMockBackend: ConversationFileBackend, @unchecked Sendable {
    public typealias Sleep = @Sendable (Duration) async -> Void
    let engine: Engine

    /// `sleep` paces Chief (pass a no-op in tests); `now` stamps messages.
    public init(identity: ChiefIdentity = .standard, now: Date = Date(),
                sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }) {
        engine = Engine(identity: identity, now: now, sleep: sleep)
        self.sleep = sleep
        questionFeed.update([ChiefMockScript.question], seq: ChiefMockScript.questionSeq)
    }

    let sleep: Sleep
    /// The seeded transcript's last message asks to allow a command.
    public let questionFeed = ChiefQuestionFeed()

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await engine.connect(continuation) }
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        await engine.history(beforeSeq: beforeSeq, limit: limit)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        await engine.send(draft)
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        try await engine.react(messageID: messageID, reaction: reaction)
    }

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await engine.update(messageID) { $0.text = text; $0.editedAt = Date(); $0.editCount += 1 }
    }

    public func unsend(messageID: String) async throws -> ConversationMessage {
        try await engine.update(messageID) { $0.text = ""; $0.unsentAt = Date(); $0.reactions = [] }
    }

    public func setTyping(_ isTyping: Bool) async {}

    public func markRead(upToSeq: Int) async {
        await engine.markRead(upToSeq)
    }

    /// Keeps the bytes in memory; the sent message carries them, so the
    /// bubble renders without a URL.
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        let size = ChiefImageSize(data: data)
        return await engine.upload(ConversationAttachment(
            id: "", kind: .image, width: size.width, height: size.height, url: nil, localData: data
        ))
    }

    public func uploadFileAttachment(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment {
        await engine.upload(ConversationAttachment(id: "", kind: .file, width: 0, height: 0, url: nil, localData: data, file: info))
    }

    public func close() {
        Task { await engine.close() }
    }

    /// Posts Chief's three cards (browser, next step, Secure Store): the demo's `chief-cards`.
    public func postCardsDemo() async {
        await engine.postCards()
    }

    /// Hide Alerts and Send Read Receipts, kept for this run only.
    public func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
        await engine.updateListState(change)
    }

    actor Engine {
        let identity: ChiefIdentity
        let sleep: Sleep
        let conversationID = "conv_chief_local"
        private var messages: [ConversationMessage] = []
        private var eventSeq = 0
        private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        private var replyIndex = 0
        private var uploads: [String: ConversationAttachment] = [:]
        private var listState = ConversationListState(pinned: true, pinOrder: 0)

        func updateListState(_ change: ConversationListStateChange) -> ConversationInfo {
            listState = listState.applying(change)
            var info = identity.info(id: conversationID)
            info.listState = listState
            return info
        }

        init(identity: ChiefIdentity, now: Date, sleep: @escaping Sleep) {
            self.identity = identity
            self.sleep = sleep
            messages = ChiefMockScript.history(identity: identity, now: now)
        }

        private var headSeq: Int { messages.compactMap(\.seq).max() ?? 0 }

        func connect(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
            self.continuation = continuation
            continuation.yield(.connected(info: identity.info(id: conversationID), meID: identity.meID, lagged: false))
            continuation.yield(.readState(ConversationReadState(lastReadSeq: headSeq, unreadCount: 0, headSeq: headSeq)))
        }

        func close() {
            continuation?.finish()
            continuation = nil
        }

        func history(beforeSeq: Int?, limit: Int) -> ConversationHistoryPage {
            let eligible = messages.filter { message in beforeSeq.map { (message.seq ?? 0) < $0 } ?? true }
            let page = Array(eligible.suffix(limit))
            return ConversationHistoryPage(messages: page, hasMore: eligible.count > page.count)
        }

        private func emit(_ message: ConversationMessage) {
            eventSeq += 1
            continuation?.yield(.message(message, eventSeq: eventSeq))
        }

        private func store(_ message: ConversationMessage) {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }

        func upload(_ attachment: ConversationAttachment) -> ConversationAttachment {
            let stored = ConversationAttachment(
                id: "att_local_\(uploads.count + 1)", kind: attachment.kind, width: attachment.width, height: attachment.height,
                url: nil, localData: attachment.localData, audio: attachment.audio, file: attachment.file
            )
            uploads[stored.id] = stored
            return stored
        }

        func send(_ draft: ConversationOutgoingDraft) -> ConversationMessage {
            if let existing = messages.first(where: { $0.clientMessageID == draft.clientMessageID }) { return existing }
            let seq = headSeq + 1
            let message = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: draft.clientMessageID, senderID: identity.meID,
                sentAt: Date(), text: draft.text, replyToID: draft.replyToID,
                attachments: draft.attachmentIDs.compactMap { uploads[$0] }, delivery: .delivered,
                mentions: draft.mentions, textRuns: draft.textRuns, effect: draft.effect
            )
            store(message)
            emit(message)
            Task { await self.respond(to: message) }
            return message
        }

        /// Read receipt, typing, then the reply (and a tapback when earned).
        func respond(to message: ConversationMessage) async {
            await sleep(.milliseconds(700))
            guard var read = messages.first(where: { $0.id == message.id }) else { return }
            read.delivery = .read(Date())
            store(read)
            emit(read)
            if let reaction = ChiefMockScript.tapback(for: message.text) {
                await sleep(.milliseconds(450))
                if var reacted = messages.first(where: { $0.id == message.id }) {
                    reacted.reactions.removeAll { $0.participantID == identity.chiefID }
                    reacted.reactions.append(ConversationReactionMark(participantID: identity.chiefID, reaction: reaction))
                    store(reacted)
                    emit(reacted)
                }
            }
            await sleep(.milliseconds(400))
            continuation?.yield(.typing(participantID: identity.chiefID, isTyping: true))
            let reply = message.text.isEmpty && !message.attachments.isEmpty
                ? ChiefMockScript.photoReply(count: message.attachments.count)
                : ChiefMockScript.reply(to: message.text, index: replyIndex)
            replyIndex += 1
            // Typing time grows with the reply, as a person's would.
            await sleep(.milliseconds(min(2600, 900 + reply.count * 12)))
            let seq = headSeq + 1
            let answer = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: "chief-\(seq)", senderID: identity.chiefID,
                sentAt: Date(), text: reply
            )
            store(answer)
            emit(answer)
            continuation?.yield(.typing(participantID: identity.chiefID, isTyping: false))
        }

        func react(messageID: String, reaction: ConversationReaction?) throws -> ConversationMessage {
            try update(messageID) { message in
                message.reactions.removeAll { $0.participantID == self.identity.meID }
                if let reaction {
                    message.reactions.append(ConversationReactionMark(participantID: self.identity.meID, reaction: reaction))
                }
            }
        }

        func update(_ messageID: String, _ change: (inout ConversationMessage) -> Void) throws -> ConversationMessage {
            guard var message = messages.first(where: { $0.id == messageID }) else {
                throw ConversationBackendError(code: 404, message: "unknown message")
            }
            change(&message)
            store(message)
            emit(message)
            return message
        }

        /// Chief's three cards (https://github.com/manaflow-ai/cmux/issues/25830):
        /// a live browser card that moves to its next step, a reply with a
        /// next-step chip, and a Secure Store sign-in card.
        func postCards() async {
            let screenshot = ChiefMockScript.screenshot()
            var seq = headSeq + 1
            let browserID = "msg_local_\(seq)"
            let image = screenshot.map {
                ConversationAttachment(id: "att:mock-screenshot-1", kind: .image, width: 1280, height: 800, url: nil, localData: $0)
            }
            let browser = ConversationMessage(
                id: browserID, seq: seq, clientMessageID: "chief-\(seq)", senderID: identity.chiefID, sentAt: Date(), text: "",
                cards: ConversationBrowserCard(surface: .browser, step: "Opening LinkedIn Messaging", live: true,
                                               target: .browserRight, url: URL(string: "https://www.linkedin.com/messaging/"),
                                               image: image).map { [ConversationCard.browser($0)] } ?? []
            )
            store(browser)
            emit(browser)
            await sleep(.milliseconds(1500))
            // The same message, edited as the agent moves on (a new screenshot, the turn over).
            _ = try? update(browserID) { message in
                let next = image.map { ConversationAttachment(id: "att:mock-screenshot-2", kind: .image, width: $0.width, height: $0.height, url: nil, localData: $0.localData) }
                message.cards = ConversationBrowserCard(surface: .browser, step: "Returning to LinkedIn Messaging", live: false,
                                                        target: .browserRight, url: URL(string: "https://www.linkedin.com/messaging/"),
                                                        image: next).map { [ConversationCard.browser($0)] } ?? []
                message.editedAt = nil
            }
            seq = headSeq + 1
            let reply = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: "chief-\(seq)", senderID: identity.chiefID, sentAt: Date(),
                text: "The apology replies to Jeff and daval.ai are sent and verified. The Jun Beom Lee LinkedIn reply for Wed Oct 28 at 10 AM is in progress.",
                cards: ConversationNextSteps(choices: ["Try sending the Kernel update again"]).map { [ConversationCard.nextSteps($0)] } ?? []
            )
            store(reply)
            emit(reply)
            seq = headSeq + 1
            let signIn = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: "chief-\(seq)", senderID: identity.chiefID, sentAt: Date(), text: "",
                cards: ConversationSignInCard(site: "linkedin.com", url: URL(string: "https://www.linkedin.com/login")).map { [ConversationCard.signIn($0)] } ?? []
            )
            store(signIn)
            emit(signIn)
        }

        /// A message from Chief now (the mock's answer to an answered question).
        func post(_ text: String) {
            let seq = headSeq + 1
            let message = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: "chief-\(seq)", senderID: identity.chiefID,
                sentAt: Date(), text: text
            )
            store(message)
            emit(message)
        }

        func markRead(_ seq: Int) {
            let head = headSeq
            let read = min(seq, head)
            let unread = messages.filter { ($0.seq ?? 0) > read && $0.senderID != identity.meID }.count
            continuation?.yield(.readState(ConversationReadState(lastReadSeq: read, unreadCount: unread, headSeq: head)))
        }
    }
}

/// The mock answers like the Mac: a pause where Face ID would be (mock
/// only: nothing is signed), then the question reads as answered and Chief
/// replies. Layout and flow only.
extension ChiefMockBackend: ChiefQuestionSource {
    public func recheckQuestions() async throws {}

    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer, signer: (any ChiefAnswerSigning)?,
                       approved: @escaping @Sendable () -> Void) async throws {
        await sleep(.milliseconds(1400))
        approved()
        await sleep(.milliseconds(600))
        questionFeed.update([AgentQuestion(id: question.id, source: question.source, items: question.items,
                                           state: .answered(answer))], seq: ChiefMockScript.questionSeq)
        let allowed = answer.selections.values.contains { $0.optionIDs.contains("allow") }
        await engine.post(allowed ? "Allowed. Claude is running cargo test -p cmux-mobile-link in cmux now."
                                  : "Told Claude not to run it. It will ask before trying another way.")
    }
}

/// Chief's seeded transcript and canned replies.
struct ChiefMockScript {
    /// A stand-in browser screenshot: a white page with a gray "Choose an
    /// account" box, PNG-encoded (CoreGraphics and ImageIO, so it builds on
    /// macOS for `swift test` too).
    static func screenshot(width: Int = 1280, height: Int = 800) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1))
        context.setLineWidth(3)
        let box = CGRect(x: width * 3 / 8, y: height / 3, width: width / 4, height: height / 2)
        context.stroke(box)
        context.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        for row in 0..<2 {
            context.fill(CGRect(x: box.minX + 24, y: box.maxY - 120 - CGFloat(row) * 100, width: box.width - 48, height: 72))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The question part of the seeded transcript's last message (seq 8).
    static let questionSeq = 8
    static let question = AgentQuestion(
        id: "msg_local_8#1",
        source: .init(harness: .chief, session: "chief", agentName: "Claude"),
        items: [.init(id: "allow", header: "Permission", prompt: "Allow Claude in cmux to run cargo test -p cmux-mobile-link?",
                      options: [.init(id: "allow", label: "Allow", detail: "Runs once, in the cmux workspace"),
                                .init(id: "deny", label: "Don't Allow")],
                      multiSelect: false, allowsOther: false)])

    static func history(identity: ChiefIdentity, now: Date) -> [ConversationMessage] {
        let lines: [(me: Bool, minutesAgo: Double, text: String)] = [
            (false, 26 * 60, "Morning. Overnight: Codex finished the pricing page fix on cmux.com (14 tests pass), and the fleet build for feat-cmux-next-ios is green."),
            (true, 26 * 60 - 2, "nice. anything waiting on me?"),
            (false, 26 * 60 - 3, "One thing: Claude in cmux wants to know which transport to default to on cellular. I left it in your Feed."),
            (true, 95, "Can you start a Claude session on the cmux-next-ios workspace to build the workspaces tab?"),
            (false, 94, "Started Claude in cmux-next-ios on cmux mini 2 with your note as the first prompt. I'll tell you when it needs you."),
            (false, 41, "Claude finished the TabsKit integration. It opened 3 files and ran the build: BUILD SUCCEEDED."),
            (true, 40, "🙌 thanks"),
            (false, 3, "Heads up: Claude in cmux is asking to run `cargo test -p cmux-mobile-link`. Want me to allow it?"),
        ]
        // Each reply is later than the message it answers (the send-time
        // drawer shows every time).
        assert(zip(lines, lines.dropFirst()).allSatisfy { $0.minutesAgo > $1.minutesAgo })
        var messages: [ConversationMessage] = []
        for (index, line) in lines.enumerated() {
            let seq = index + 1
            var message = ConversationMessage(
                id: "msg_local_\(seq)", seq: seq, clientMessageID: "seed-\(seq)",
                senderID: line.me ? identity.meID : identity.chiefID,
                sentAt: now.addingTimeInterval(-line.minutesAgo * 60), text: line.text,
                delivery: line.me ? .read(nil) : nil
            )
            // Chief answers the request inline (an incoming reply quoting an outgoing message).
            if seq == 5 { message.replyToID = "msg_local_4" }
            // And the user answers one of Chief's inline (an outgoing reply quoting Chief).
            if seq == 7 { message.replyToID = "msg_local_6" }
            if seq == 6 {
                message.reactions = [ConversationReactionMark(participantID: identity.meID, reaction: .heart)]
            }
            messages.append(message)
        }
        return messages
    }

    static func tapback(for text: String) -> ConversationReaction? {
        let lower = text.lowercased()
        if lower.contains("thank") || lower.contains("love") { return .heart }
        if lower.contains("great") || lower.contains("nice") || lower.contains("perfect") { return .thumbsup }
        if lower.contains("lol") || lower.contains("haha") { return .haha }
        return nil
    }

    static func photoReply(count: Int) -> String {
        count == 1
            ? "Got the photo. Want me to hand it to an agent, or keep it with this thread?"
            : "Got the \(count) photos. Want me to hand them to an agent, or keep them with this thread?"
    }

    static func reply(to text: String, index: Int) -> String {
        let lower = text.lowercased()
        if lower.contains("allow") || lower.contains("yes") || lower.contains("go ahead") {
            return "Done. I allowed `cargo test -p cmux-mobile-link` once; 42 tests passed in 6.1s. Claude is moving on to the dialers."
        }
        if lower.contains("status") || lower.contains("what's") || lower.contains("whats") || lower.contains("update") {
            return "3 workspaces are active. cmux: Claude is waiting on you (1 permission). cmux.com: Codex is working on the pricing page. fleet: idle for 2h."
        }
        if lower.contains("test") {
            return "Running the tests in cmux on Aziz's Mac Studio now. I'll post the result here."
        }
        if lower.contains("stop") || lower.contains("cancel") {
            return "Stopped. Nothing else is running."
        }
        let fallbacks = [
            "On it. I'll start that in the right workspace and report back here.",
            "Got it. Want me to do that on Aziz's Mac Studio or on cmux mini 2?",
            "Sure. I'll keep an eye on it and ping you only if an agent needs a decision.",
        ]
        return fallbacks[index % fallbacks.count]
    }
}
#endif

/// Pixel size of encoded image bytes (JPEG, PNG, HEIC), read from the header.
struct ChiefImageSize {
    var width = 0
    var height = 0

    init(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // EXIF orientations 5-8 are rotated a quarter turn.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        self.width = width
        self.height = height
    }
}
