import CmuxHomeCore
import CoreGraphics
import Foundation

/// What row derivation needs besides the items.
struct RowContext {
    var me: ParticipantID
    var now: Date
    var metrics: Metrics
    /// The highest seq another participant has read (nil: nobody read anything).
    var readByOthers: Seq?
    /// Someone other than me is typing.
    var othersTyping: Bool
    /// Display names by participant; with `showsNames` (a group
    /// conversation) the first bubble of another sender's run is labeled.
    var names: [ParticipantID: String] = [:]
    var showsNames = false
}

/// Derives the transcript rows from CmuxHomeCore items.
@MainActor
final class RowBuilder {
    /// Consecutive messages from one sender closer than this form a run:
    /// tight gaps, one tail on the last bubble, one name on the first.
    static let groupGap: TimeInterval = 5 * 60
    static let separatorGap: TimeInterval = 15 * 60

    let format: RowFormat
    let measure = MeasureCache()
    /// Attachment layouts by ref and text column (file chips measure and
    /// truncate their name with Core Text; a commit must not redo that).
    private var attachments: [AttachmentKey: (PartContent, CGSize)] = [:]

    private struct AttachmentKey: Hashable {
        var ref: AttachmentRef
        var width: CGFloat
    }

    init(format: RowFormat) { self.format = format }

    func rows(_ items: [TranscriptItem], _ ctx: RowContext) -> [RowSpec] {
        var rows: [RowSpec] = []
        rows.reserveCapacity(items.count + 4)
        let receipts = Self.receipts(items, me: ctx.me, readByOthers: ctx.readByOthers)
        var prev: TranscriptItem?
        for (index, item) in items.enumerated() {
            let next = index + 1 < items.count ? items[index + 1] : nil
            let outgoing = item.author == ctx.me
            var gap: CGFloat
            if let p = prev, item.createdAt.timeIntervalSince(p.createdAt) <= Self.separatorGap {
                if p.author == item.author, item.createdAt.timeIntervalSince(p.createdAt) < Self.groupGap {
                    gap = 3
                } else if p.author != item.author {
                    gap = 32
                } else {
                    gap = 12
                }
            } else {
                let separator = RowSpec.Kind.separator(bold: format.day(item.createdAt, now: ctx.now), rest: format.time(item.createdAt))
                rows.append(RowSpec(key: "sep:\(item.key.rawValue)", kind: separator, gap: prev == nil ? 12 : 0, height: 35.5))
                gap = 0
            }
            let startsRun = prev.map { $0.author != item.author || item.createdAt.timeIntervalSince($0.createdAt) >= Self.groupGap } ?? true
            if ctx.showsNames, !outgoing, startsRun, !item.isRetracted, let name = ctx.names[item.author], !name.isEmpty {
                rows.append(RowSpec(key: "name:\(item.key.rawValue)", kind: .senderName(name), gap: gap, height: 14))
                gap = 1
            }
            prev = item
            if item.isRetracted {
                rows.append(RowSpec(key: "unsent:\(item.key.rawValue)", kind: .unsent(outgoing: outgoing), gap: max(gap, 8), height: 16))
                continue
            }
            let lastOfGroup = next.map {
                $0.author != item.author || $0.createdAt.timeIntervalSince(item.createdAt) >= Self.groupGap || $0.isRetracted
            } ?? true
            let failed = if case .notDelivered = item.delivery { true } else { false }
            let parts = item.parts.enumerated().filter { Self.shows($0.element) }
            for (position, (pi, part)) in parts.enumerated() {
                let (content, size) = content(of: part, item: item.key, index: pi, metrics: ctx.metrics)
                let reactions = item.reactions.filter { $0.partIndex == pi }.map {
                    ReactionBadge(glyph: Self.glyph($0.kind), mine: $0.author == ctx.me)
                }
                var g = position == 0 ? gap : 3
                if !reactions.isEmpty { g += 10 }
                let row = PartRow(outgoing: outgoing, tail: lastOfGroup && position == parts.count - 1, failed: failed,
                                  reactions: reactions, size: size, content: content)
                rows.append(RowSpec(key: "part:\(item.key.rawValue):\(pi)", kind: .part(row), gap: g, height: size.height))
            }
            if failed {
                rows.append(RowSpec(key: "failed:\(item.key.rawValue)", kind: .failedLabel(item.mayHaveBeenDelivered ? HomeStrings.mayNotHaveBeenDelivered : HomeStrings.notDelivered), gap: 1, height: 14))
            }
            if let receipt = receipts[item.key] {
                rows.append(RowSpec(key: "receipt:\(item.key.rawValue)", kind: .receipt(receipt), gap: 0, height: 16))
            }
        }
        if ctx.othersTyping {
            rows.append(RowSpec(key: "typing", kind: .typing, gap: 0, height: 35))
        }
        measure.trim(keeping: Set(items.map(\.key)))
        return rows
    }

    /// Attachments always show; other parts when they have text.
    static func shows(_ part: MessagePart) -> Bool {
        if case .attachment = part { return true }
        return !part.plainText.isEmpty
    }

    /// An attachment's media bubble or file chip, or the measured text.
    private func content(of part: MessagePart, item: IdempotencyKey, index: Int, metrics: Metrics) -> (PartContent, CGSize) {
        if case .attachment(let ref) = part {
            let key = AttachmentKey(ref: ref, width: metrics.maxTextWidth)
            if let hit = attachments[key] { return hit }
            if attachments.count > 512 { attachments.removeAll(keepingCapacity: true) }
            let laid = AttachmentLayout.content(of: ref, metrics: metrics)
            attachments[key] = laid
            return laid
        }
        let (text, bold) = Self.text(of: part)
        let measured = measure.measure(item: item, part: index, text: text, bold: bold, wrapWidth: metrics.maxTextWidth)
        return (.text(measured.layout), measured.size)
    }

    /// The row's text and its bold (mention) ranges.
    static func text(of part: MessagePart) -> (String, [NSRange]) {
        if case .text(let text, let mentions) = part {
            return (text, mentions.map { NSRange(location: $0.start, length: $0.length) })
        }
        return (part.plainText, [])
    }

    static func glyph(_ kind: Reaction.Kind) -> String {
        HomeReactionStyle().glyph(kind)
    }

    /// "Read" under my latest send another participant has read; "Delivered"
    /// under my latest committed send when it is newer than that.
    static func receipts(_ items: [TranscriptItem], me: ParticipantID, readByOthers: Seq?) -> [IdempotencyKey: String] {
        var lastRead: (index: Int, key: IdempotencyKey)?
        var lastCommitted: (index: Int, key: IdempotencyKey)?
        for (i, item) in items.enumerated() where item.author == me && !item.isRetracted && item.delivery == .committed {
            guard let seq = item.seq else { continue }
            lastCommitted = (i, item.key)
            if let read = readByOthers, seq <= read { lastRead = (i, item.key) }
        }
        var out: [IdempotencyKey: String] = [:]
        if let r = lastRead { out[r.key] = HomeStrings.read }
        if let d = lastCommitted, d.index > (lastRead?.index ?? -1) { out[d.key] = HomeStrings.delivered }
        return out
    }
}
