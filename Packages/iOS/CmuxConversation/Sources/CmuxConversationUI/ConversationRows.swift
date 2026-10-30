#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// One visual row of the transcript.
enum ConversationRow: Hashable {
    case conversationStart
    case loadingOlder
    case timestamp(id: String, date: Date)
    /// Boxed: rows are copied and compared over the whole transcript on every
    /// update, and a boxed payload copies as one reference.
    indirect case message(MessageRowModel)
    case typing(participantIDs: [String])
    /// A centered system line in a message's place ("You unsent a message").
    case notice(ConversationNotice)
    /// "Send Later <time> Edit" above a scheduled message.
    case sendLaterHeader(rowID: String, date: Date, failed: Bool)
    /// A group change ("Lawrence Chen named the conversation …"): centered,
    /// the actor's name emphasized, wrapping when long.
    case systemEvent(id: String, text: ConversationSystemText)
    /// "<Name> has notifications silenced" under the newest message, with
    /// Notify Anyway while my newest message was delivered quietly.
    case unavailability(name: String, notifyAnywayMessageID: String?)

    var id: String {
        switch self {
        case .conversationStart: return "start"
        case .loadingOlder: return "loading"
        case let .timestamp(id, _): return id
        case let .message(model): return model.rowID
        case .typing: return "typing"
        case let .notice(notice): return notice.id
        case let .sendLaterHeader(rowID, _, _): return "sl:\(rowID)"
        case let .systemEvent(id, _): return id
        case .unavailability: return "unavailability"
        }
    }
}

struct ReplyQuote: Hashable {
    var text: String
    var isOutgoing: Bool
    var hasImage: Bool
}

enum MessageFooter: Hashable {
    case none
    /// "Delivered", or "Read" with its time drawn in the regular weight.
    case status(String, detail: String? = nil)
    case notDelivered
}

struct MessageRowModel: Hashable {
    var rowID: String
    var message: ConversationMessage
    var isOutgoing: Bool
    var senderName: String?
    var senderInitials: String
    var senderColorHex: String
    var showsSenderName: Bool
    var showsAvatar: Bool
    /// Leaves room for an avatar column (group chats, incoming).
    var reservesAvatarColumn: Bool
    var isGroup: Bool
    var showsTail: Bool
    var isFirstInGroup: Bool
    var footer: MessageFooter
    var replyQuote: ReplyQuote?
    var isEmojiOnly: Bool
    /// Distinct tapbacks in first-given order, and whether one of them is mine.
    var reactionKinds: [ConversationReaction]
    var hasMyReaction: Bool
    /// Mentions of this participant are highlighted in incoming bubbles.
    var meID: String? = nil
    /// Rich link card and the text left beside it, when the message has one.
    var linkSplit: ConversationLinkSplit? = nil

    /// Text bubble content: the message text, minus a URL shown as a card.
    var bodyText: String { linkSplit?.bodyText ?? message.text }
    /// Set for poll messages (see ConversationPolls.swift).
    var poll: PollRowModel? = nil
    /// "Show Original" / "View Translation" and friends under a translated bubble.
    var translation: ConversationTranslationCaption? = nil
}

/// The rows each message produced last time, with what they were built
/// from: a rebuild over a long transcript (a typing indicator, a message
/// arriving) copies the rows of every message whose inputs are unchanged
/// instead of building them again, and tells the diff which rows are the
/// ones already shown.
@MainActor
final class ConversationRowMemo {
    struct Inputs: Equatable {
        var message: ConversationMessage
        var entry: ConversationRunPlan.Entry
        var translation: String?
        var caption: ConversationTranslationCaption?
        var quoted: ConversationMessage?
    }

    /// A class, so a hit only bumps its generation in place.
    fileprivate final class Entry {
        let inputs: Inputs
        let rows: [ConversationRow]
        var generation: Int

        init(inputs: Inputs, rows: [ConversationRow], generation: Int) {
            self.inputs = inputs
            self.rows = rows
            self.generation = generation
        }
    }

    fileprivate var context: ConversationInfo?
    fileprivate var contextMeID: String?
    fileprivate var entries: [String: Entry] = [:]
    /// Build passes so far; the rows on screen came from `appliedGeneration`.
    fileprivate(set) var generation = 0
    var appliedGeneration = -1
    /// Ids of rows the last pass copied from the pass on screen.
    fileprivate(set) var unchangedRowIDs: Set<String> = []

    /// Forgets a message's rows (they were built outside a pass, so the
    /// copy here may not be what is on screen).
    func forget(messageRowID: String) {
        entries[messageRowID] = nil
    }

    fileprivate func beginPass(info: ConversationInfo, meID: String?, messageCount: Int) {
        generation += 1
        unchangedRowIDs.removeAll(keepingCapacity: true)
        if context != info || contextMeID != meID {
            context = info
            contextMeID = meID
            entries.removeAll()
        } else if entries.count > 2 * messageCount + 64 {
            entries = entries.filter { $0.value.generation >= generation - 1 }
        }
    }
}

/// Row positions by identity. A page landing above the transcript moves
/// every row down by the same amount; that move is kept as one offset, so
/// the landing updates the page's entries instead of every row's.
struct ConversationRowIndex {
    private var stored: [String: Int]
    private var base = 0

    init() { stored = [:] }

    init(_ positions: [String: Int]) { stored = positions }

    subscript(id: String) -> Int? {
        stored[id].map { $0 + base }
    }

    /// The first `oldPrefix` rows gave way to `newPrefix`; every row after
    /// them moved by the difference in count.
    mutating func replacePrefix(_ oldPrefix: ArraySlice<String>, with newPrefix: [String]) {
        for id in oldPrefix { stored[id] = nil }
        base += newPrefix.count - oldPrefix.count
        for (index, id) in newPrefix.enumerated() { stored[id] = index - base }
    }

    /// The rows from `start` on (`oldSuffix`) gave way to `newSuffix`.
    mutating func replaceSuffix(from start: Int, _ oldSuffix: ArraySlice<String>, with newSuffix: [String]) {
        for id in oldSuffix { stored[id] = nil }
        for (offset, id) in newSuffix.enumerated() { stored[id] = start + offset - base }
    }
}

/// Rows after an older page landed: `rows[reused]` are the previous rows
/// from `keptFrom` on, except `rebuilt` (a reply that gained its quote).
struct ConversationPrependRows {
    var rows: [ConversationRow]
    var reused: Range<Int>
    var keptFrom: Int
    var rebuilt: [Int]
}

/// Rows after a live change: `rows[..<kept]` are the previous rows, except
/// `rebuilt`; the rows from `kept` on were built again.
struct ConversationTailRows {
    var rows: [ConversationRow]
    var kept: Int
    var rebuilt: [Int]
}

/// Builds rows from store state with Messages grouping rules: consecutive
/// messages from one sender group (tail on the last), a timestamp separates
/// gaps of an hour, sender names and avatars appear only in group chats.
@MainActor
enum ConversationRowBuilder {
    /// Store state every row of one pass reads.
    private struct Context {
        var store: ConversationStore
        var info: ConversationInfo
        var isGroup: Bool
        var meID: String?
        var typingIDs: [String]
        var translations: ConversationTranslations
    }

    static func rows(
        store: ConversationStore,
        hidesLoadingRow: Bool = false,
        memo: ConversationRowMemo? = nil
    ) -> [ConversationRow] {
        guard let info = store.info else { return [] }
        memo?.beginPass(info: info, meID: store.meID, messageCount: store.messages.count)
        var rows: [ConversationRow] = []
        rows.reserveCapacity(store.messages.count * 2 + 3)
        appendLeadingRows(store: store, hidesLoadingRow: hidesLoadingRow, into: &rows)
        let messages = store.messages
        let context = Context(store: store, info: info, isGroup: info.kind == .group, meID: store.meID, typingIDs: store.typingParticipantIDs, translations: store.translations)
        let plan = ConversationRunPlan(messages: messages, meID: context.meID, typingParticipantIDs: context.typingIDs)
        var typingPlaced = context.typingIDs.isEmpty
        for (index, original) in messages.enumerated() {
            appendRows(for: original, entry: plan.entries[index], context: context, memo: memo, typingPlaced: &typingPlaced, into: &rows)
        }
        // The Focus notice ends the transcript, above typing and Send Later rows.
        if let silenced = info.silencedRecipient {
            let slot = rows.firstIndex { row in
                switch row {
                case .typing, .sendLaterHeader: return true
                default: return false
                }
            } ?? rows.count
            rows.insert(.unavailability(name: firstName(silenced.name), notifyAnywayMessageID: store.notifyAnywayMessage?.id), at: slot)
        }
        if !typingPlaced {
            rows.append(.typing(participantIDs: context.typingIDs))
        }
        return rows
    }

    /// The rows `rows(store:)` gives after an older page landed above the
    /// rows `previous` (built from this store before the page), built from
    /// the page alone: the page's rows and those of the message under it
    /// (its timestamp and grouping depend on the page) are built, the rows
    /// below come from `previous`, and a row below that quotes a message of
    /// the page is rebuilt. `reused` are the indices of rows taken from
    /// `previous` (from `keptFrom` on); of those, `rebuilt` were rebuilt.
    /// `index` finds a row of `previous` by id. Nil when the change is not
    /// such a landing.
    static func rowsAfterPrepend(store: ConversationStore, previous: [ConversationRow], index: (String) -> Int?) -> ConversationPrependRows? {
        guard let info = store.info else { return nil }
        let messages = store.messages
        // The first message of the previous rows, and where it is now.
        guard let firstOldRow = previous.firstIndex(where: { messageRowID(of: $0) != nil }),
              let firstOldID = messageRowID(of: previous[firstOldRow]),
              let boundary = messages.firstIndex(where: { $0.rowID == firstOldID }), boundary > 0,
              !messages[0...boundary].contains(where: \.isScheduled) else { return nil }
        // The previous rows from the second old message on are kept.
        var keepFrom = previous.count
        if boundary + 1 < messages.count {
            let secondID = messages[boundary + 1].rowID
            guard let index = previous[firstOldRow...].firstIndex(where: { messageRowID(of: $0) == secondID }),
                  !previous[firstOldRow..<index].contains(where: { messageRowID(of: $0) != firstOldID }) else { return nil }
            keepFrom = index
        } else {
            keepFrom = previous[firstOldRow...].firstIndex(where: { messageRowID(of: $0) != firstOldID }) ?? previous.count
        }
        var rows: [ConversationRow] = []
        rows.reserveCapacity((boundary + 1) * 2 + 1 + previous.count - keepFrom)
        appendLeadingRows(store: store, hidesLoadingRow: false, into: &rows)
        let context = Context(store: store, info: info, isGroup: info.kind == .group, meID: store.meID, typingIDs: store.typingParticipantIDs, translations: store.translations)
        let plan = ConversationRunPlan(messages: messages, meID: context.meID, typingParticipantIDs: context.typingIDs, limit: boundary + 1)
        var typingPlaced = true
        for index in 0...boundary {
            appendRows(for: messages[index], entry: plan.entries[index], context: context, typingPlaced: &typingPlaced, into: &rows)
        }
        let reusedStart = rows.count
        rows.append(contentsOf: previous[keepFrom...])
        // A reply below whose quoted message just arrived gains its quote.
        // The replies are found among the messages under the page (a field
        // read each), not by copying every reused row's model; each one's
        // row is where `previous` had it, moved by the splice.
        var pageIDs = Set<String>()
        for message in messages[0..<boundary] { pageIDs.insert(message.id) }
        var rebuilt: [Int] = []
        for i in store.messageIndices(from: boundary + 1, replyingTo: pageIDs) {
            let rowID = messages[i].rowID
            // A reply the rows on screen do not show yet (a live change
            // held meanwhile) is not among the reused rows.
            guard let old = index(rowID) else { continue }
            let row = reusedStart + old - keepFrom
            guard old >= keepFrom, row < rows.count else { return nil }
            // Only a bubble shows the quote (an unsent reply is a notice).
            guard case let .message(model) = rows[row] else { continue }
            guard model.rowID == rowID else { return nil }
            let entry = ConversationRunPlan(messages: messages, meID: context.meID, typingParticipantIDs: context.typingIDs, range: i..<(i + 1)).entries[0]
            var single: [ConversationRow] = []
            var placed = true
            appendRows(for: messages[i], entry: entry, context: context, typingPlaced: &placed, into: &single)
            guard let replacement = single.first(where: { $0.id == rowID }) else { return nil }
            rows[row] = replacement
            rebuilt.append(row)
        }
        return ConversationPrependRows(rows: rows, reused: reusedStart..<rows.count, keptFrom: keepFrom, rebuilt: rebuilt.sorted())
    }

    /// The rows `rows(store:)` gives after a live change (an arrival, an
    /// update, typing) that left the first `unchanged` messages as they were
    /// when `previous` was built (`ConversationStore.unchangedMessagePrefix`),
    /// built from the end alone: the rows of the messages from the one
    /// above the first changed message (its tail depends on the next) or
    /// the last message before Send Later (its tail depends on typing) on,
    /// and the transcript's trailing rows, are built; the rows above come
    /// from `previous`, except a bubble whose delivery status moved or whose
    /// quoted message is among the rebuilt ones, which is rebuilt.
    /// `statusMessageID` is the message that carried the status in
    /// `previous`; `index` finds a row of `previous` by id. The rebuilt
    /// messages are copied from `memo` when unchanged, so a change far up
    /// costs no more than a full build. Nil when the rows cannot be split
    /// that way.
    static func rowsAfterLiveChange(
        store: ConversationStore,
        previous: [ConversationRow],
        index: (String) -> Int?,
        unchanged: Int,
        statusMessageID: String?,
        memo: ConversationRowMemo? = nil
    ) -> ConversationTailRows? {
        guard let info = store.info else { return nil }
        let messages = store.messages
        var firstScheduled = messages.count
        while firstScheduled > 0, messages[firstScheduled - 1].isScheduled { firstScheduled -= 1 }
        let start = min(unchanged, firstScheduled) - 1
        // Near the top, a full build costs as little.
        guard start > 0, start < messages.count else { return nil }
        // Where the first rebuilt message's rows began.
        let startRowID = messages[start].rowID
        var cut = Int.max
        for id in ["ts:\(startRowID)", "unsent:\(startRowID)", "system:\(startRowID)", startRowID] {
            if let row = index(id) { cut = min(cut, row) }
        }
        guard cut < previous.count, cut > 0, messageRowID(of: previous[cut]) == startRowID,
              messageRowID(of: previous[cut - 1]) != startRowID else { return nil }
        // The leading row is as before, and no trailing row sits above the cut.
        var leading: [ConversationRow] = []
        appendLeadingRows(store: store, hidesLoadingRow: false, into: &leading)
        guard previous.starts(with: leading) else { return nil }
        if case .conversationStart = previous[leading.count] { return nil }
        if case .loadingOlder = previous[leading.count] { return nil }
        for id in ["typing", "unavailability"] {
            if let row = index(id), row < cut { return nil }
        }
        let context = Context(store: store, info: info, isGroup: info.kind == .group, meID: store.meID, typingIDs: store.typingParticipantIDs, translations: store.translations)
        let plan = ConversationRunPlan(messages: messages, meID: context.meID, typingParticipantIDs: context.typingIDs, range: start..<messages.count)
        memo?.beginPass(info: info, meID: context.meID, messageCount: messages.count)
        var rows = Array(previous[..<cut])
        rows.reserveCapacity(cut + (messages.count - start) * 2 + 2)
        var typingPlaced = context.typingIDs.isEmpty
        for index in start..<messages.count {
            appendRows(for: messages[index], entry: plan.entries[index - start], context: context, memo: memo, typingPlaced: &typingPlaced, into: &rows)
        }
        // The Focus notice ends the transcript, above typing and Send Later rows.
        if let silenced = info.silencedRecipient {
            let slot = rows[cut...].firstIndex { row in
                switch row {
                case .typing, .sendLaterHeader: return true
                default: return false
                }
            } ?? rows.count
            rows.insert(.unavailability(name: firstName(silenced.name), notifyAnywayMessageID: store.notifyAnywayMessage?.id), at: slot)
        }
        if !typingPlaced {
            rows.append(.typing(participantIDs: context.typingIDs))
        }
        // Bubbles above the cut whose status moved or whose quote may have changed.
        var stale: [Int] = []
        if let statusMessageID, let old = store.messageIndex(id: statusMessageID), old < start { stale.append(old) }
        if let new = plan.statusIndex, new < start, !stale.contains(new) { stale.append(new) }
        for i in 0..<start {
            guard let replyTo = messages[i].replyToID else { continue }
            if let quoted = store.messageIndex(id: replyTo), quoted < start { continue }
            if !stale.contains(i) { stale.append(i) }
        }
        var rebuilt: [Int] = []
        for i in stale {
            let rowID = messages[i].rowID
            guard let row = index(rowID), row < cut else { continue }
            guard case .message = previous[row] else { return nil }
            let entry = ConversationRunPlan(messages: messages, meID: context.meID, typingParticipantIDs: context.typingIDs, range: i..<(i + 1)).entries[0]
            var single: [ConversationRow] = []
            var placed = true
            appendRows(for: messages[i], entry: entry, context: context, typingPlaced: &placed, into: &single)
            guard let replacement = single.first(where: { $0.id == rowID }) else { return nil }
            rows[row] = replacement
            rebuilt.append(row)
        }
        return ConversationTailRows(rows: rows, kept: cut, rebuilt: rebuilt.sorted())
    }

    /// The message carrying the delivery status in `store` now.
    static func statusMessageID(store: ConversationStore) -> String? {
        ConversationRunPlan(messages: store.messages, meID: store.meID, range: 0..<0).statusIndex.map { store.messages[$0].id }
    }

    /// The message a row belongs to (its bubble, timestamp, notice, status
    /// line or Send Later header), or nil for rows of the transcript itself.
    static func messageRowID(of row: ConversationRow) -> String? {
        switch row {
        case let .message(model): return model.rowID
        case let .timestamp(id, _): return id.hasPrefix("ts:") ? String(id.dropFirst(3)) : nil
        case let .notice(notice): return notice.id.hasPrefix("unsent:") ? String(notice.id.dropFirst(7)) : nil
        case let .systemEvent(id, _): return id.hasPrefix("system:") ? String(id.dropFirst(7)) : nil
        case let .sendLaterHeader(rowID, _, _): return rowID
        case .conversationStart, .loadingOlder, .typing, .unavailability: return nil
        }
    }

    private static func appendLeadingRows(store: ConversationStore, hidesLoadingRow: Bool, into rows: inout [ConversationRow]) {
        if store.older == .exhausted {
            rows.append(.conversationStart)
        } else if store.hasLoadedNewest, !hidesLoadingRow {
            // Messages keeps its load-more spinner at the top for as long as
            // older history exists; reaching it is what loads the next page.
            rows.append(.loadingOlder)
        }
    }

    /// Appends the rows of one message, copied from `memo` when they were
    /// built from the same inputs before (polls and scheduled messages read
    /// more of the store and are always built).
    private static func appendRows(for original: ConversationMessage, entry: ConversationRunPlan.Entry, context: Context, memo: ConversationRowMemo?, typingPlaced: inout Bool, into rows: inout [ConversationRow]) {
        guard let memo, !original.isScheduled, original.poll == nil else {
            appendRows(for: original, entry: entry, context: context, typingPlaced: &typingPlaced, into: &rows)
            return
        }
        let presentation = context.translations.presentation(for: original)
        let inputs = ConversationRowMemo.Inputs(
            message: original, entry: entry, translation: presentation?.text, caption: presentation?.caption,
            quoted: original.replyToID.flatMap { context.store.message(id: $0) }
        )
        if let cached = memo.entries[original.rowID], cached.inputs == inputs {
            rows.append(contentsOf: cached.rows)
            if cached.generation == memo.appliedGeneration {
                for row in cached.rows { memo.unchangedRowIDs.insert(row.id) }
            }
            cached.generation = memo.generation
            return
        }
        let start = rows.count
        appendRows(for: original, entry: entry, context: context, typingPlaced: &typingPlaced, into: &rows)
        memo.entries[original.rowID] = ConversationRowMemo.Entry(inputs: inputs, rows: Array(rows[start...]), generation: memo.generation)
    }

    private static func appendRows(for original: ConversationMessage, entry: ConversationRunPlan.Entry, context: Context, typingPlaced: inout Bool, into rows: inout [ConversationRow]) {
        let store = context.store
        let info = context.info
        let isGroup = context.isGroup
        let meID = context.meID
        // A translated bubble draws the translation; everything else
        // (grouping, quotes, ids) keys off the original message.
        let translation = context.translations.presentation(for: original)
        var message = original
        if let translation {
            // Mentions and formatting index the original text, so the
            // translation draws plain.
            message.text = translation.text
            message.mentions = []
            message.textRuns = []
            message.links = []
        }
        if message.isScheduled, let scheduledAt = message.scheduledAt {
            // Scheduled messages trail everything, typing included.
            if !typingPlaced {
                rows.append(.typing(participantIDs: context.typingIDs))
                typingPlaced = true
            }
            rows.append(.sendLaterHeader(rowID: message.rowID, date: scheduledAt, failed: message.delivery?.isFailed == true))
        }
        if entry.showsTimestamp {
            rows.append(.timestamp(id: "ts:\(message.rowID)", date: message.sentAt))
        }
        if message.isUnsent {
            // Its own id: the bubble row leaves (with the poof) and the
            // notice arrives, never a bubble cell reconfigured as a notice.
            rows.append(.notice(unsentNotice(message, meID: meID, info: info)))
            return
        }
        if let status = ConversationStatusStrings.text(for: message, meID: meID, info: info) {
            rows.append(.systemEvent(id: "system:\(message.rowID)", text: status))
            return
        }
        let groupedWithPrevious = !entry.isFirstInRun
        let nextBreaksGroup = entry.isLastInRun
        let isOutgoing = message.senderID == meID
        let sender = info.participant(message.senderID)
        let footer = footer(for: entry.status, isGroup: isGroup)
        let quote = message.replyToID.flatMap { store.message(id: $0) }.map {
            ReplyQuote(text: $0.text.isEmpty ? ($0.audioAttachment != nil ? AudioMessageStrings.audioMessage : String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)) : $0.text, isOutgoing: $0.senderID == meID, hasImage: !$0.attachments.isEmpty)
        }
        rows.append(.message(PollRowModel.attach(to: MessageRowModel(
            rowID: message.rowID,
            message: message,
            isOutgoing: isOutgoing,
            senderName: sender?.name,
            senderInitials: sender?.initials ?? "",
            senderColorHex: sender?.colorHex ?? "#8E8E93",
            showsSenderName: isGroup && !isOutgoing && (!groupedWithPrevious || quote != nil),
            showsAvatar: isGroup && !isOutgoing && nextBreaksGroup,
            reservesAvatarColumn: isGroup && !isOutgoing,
            isGroup: isGroup,
            showsTail: nextBreaksGroup || quote != nil,
            isFirstInGroup: !groupedWithPrevious,
            footer: footer,
            replyQuote: quote,
            isEmojiOnly: message.attachments.isEmpty && message.linkPreview == nil && isEmojiOnly(message.text),
            reactionKinds: message.reactions.reduce(into: [ConversationReaction]()) { kinds, mark in
                if !kinds.contains(mark.reaction) { kinds.append(mark.reaction) }
            },
            hasMyReaction: message.reactions.contains { $0.participantID == meID },
            meID: meID,
            linkSplit: ConversationLinkSplit.split(text: message.text, preview: message.linkPreview),
            translation: translation?.caption
        ), store: store)))
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    static func unsentNotice(_ message: ConversationMessage, meID: String?, info: ConversationInfo) -> ConversationNotice {
        let id = "unsent:\(message.rowID)"
        if message.senderID == meID {
            if message.unsendFailed {
                return ConversationNotice(
                    id: id, messageID: message.id,
                    template: String(localized: "conversation.unsent.status.failed", defaultValue: "#You# unsent a message. %@", bundle: .module),
                    failure: String(localized: "conversation.unsent.notUnsent", defaultValue: "(!) Not Unsent", bundle: .module)
                )
            }
            return ConversationNotice(
                id: id, messageID: message.id,
                template: String(localized: "conversation.unsent.status.mine", defaultValue: "#You# unsent a message", bundle: .module)
            )
        }
        return ConversationNotice(
            id: id, messageID: message.id,
            template: String(localized: "conversation.unsent.status.other", defaultValue: "#%@# unsent a message", bundle: .module),
            argument: firstName(message.senderID, info: info)
        )
    }

    /// The conversation list's preview line for an unsent last message.
    static func unsentPreview(_ message: ConversationMessage, meID: String?, info: ConversationInfo) -> String {
        if message.senderID == meID {
            return String(localized: "conversation.unsent.mine", defaultValue: "You unsent a message", bundle: .module)
        }
        return String(format: String(localized: "conversation.unsent.other", defaultValue: "%@ unsent a message", bundle: .module), firstName(message.senderID, info: info))
    }

    private static func firstName(_ participantID: String, info: ConversationInfo) -> String {
        info.participant(participantID)?.name.split(separator: " ").first.map(String.init) ?? ""
    }

    private static func footer(for status: ConversationRunPlan.Status, isGroup: Bool) -> MessageFooter {
        switch status {
        case .none:
            return .none
        case .notDelivered:
            return .notDelivered
        case .delivered:
            return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
        case .deliveredQuietly:
            return .status(ConversationStatusStrings.deliveredQuietly)
        case let .read(date):
            // Group chats never expose read state.
            guard !isGroup else {
                return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
            }
            let read = String(localized: "conversation.status.read", defaultValue: "Read", bundle: .module)
            return .status(read, detail: date.map(ConversationShortTime.text(for:)))
        }
    }

    /// One to three emoji and nothing else render large without a bubble.
    static func isEmojiOnly(_ text: String) -> Bool {
        guard ConversationTextScan.mayBeEmojiOnly(text) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }
}
#endif
