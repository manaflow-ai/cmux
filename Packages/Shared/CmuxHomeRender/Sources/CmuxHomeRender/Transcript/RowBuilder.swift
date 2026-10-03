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

    init(format: RowFormat) { self.format = format }

    func rows(_ items: [TranscriptItem], _ ctx: RowContext) -> [RowSpec] {
        var rows: [RowSpec] = []
        rows.reserveCapacity(items.count + 4)
        let receipts = Self.receipts(items, me: ctx.me, readByOthers: ctx.readByOthers)
        let wrap = ctx.metrics.maxTextWidth
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
            let parts = item.parts.enumerated().filter { !$0.element.plainText.isEmpty }
            for (position, (pi, part)) in parts.enumerated() {
                let (text, bold) = Self.text(of: part)
                let measured = measure.measure(item: item.key, part: pi, text: text, bold: bold, wrapWidth: wrap)
                let reactions = item.reactions.filter { $0.partIndex == pi }.map {
                    ReactionBadge(glyph: Self.glyph($0.kind), mine: $0.author == ctx.me)
                }
                var g = position == 0 ? gap : 3
                if !reactions.isEmpty { g += 10 }
                let row = PartRow(outgoing: outgoing, tail: lastOfGroup && position == parts.count - 1, failed: failed,
                                  reactions: reactions, size: measured.size, text: measured.layout)
                rows.append(RowSpec(key: "part:\(item.key.rawValue):\(pi)", kind: .part(row), gap: g, height: measured.size.height))
            }
            if failed {
                rows.append(RowSpec(key: "failed:\(item.key.rawValue)", kind: .failedLabel(HomeStrings.notDelivered), gap: 1, height: 14))
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

    /// The row's text and its bold (mention) ranges.
    static func text(of part: MessagePart) -> (String, [NSRange]) {
        if case .text(let text, let mentions) = part {
            return (text, mentions.map { NSRange(location: $0.start, length: $0.length) })
        }
        return (part.plainText, [])
    }

    static func glyph(_ kind: Reaction.Kind) -> String {
        switch kind {
        case .emoji(let emoji): emoji
        case .tapback(.love): "\u{2764}\u{FE0F}"
        case .tapback(.like): "\u{1F44D}"
        case .tapback(.dislike): "\u{1F44E}"
        case .tapback(.laugh): "\u{1F602}"
        case .tapback(.emphasize): "\u{203C}\u{FE0F}"
        case .tapback(.question): "\u{2753}"
        }
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
