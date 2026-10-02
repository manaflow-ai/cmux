import CoreGraphics
import Foundation

/// Which messages carry a receipt line (MODEL.md "Derived": "Read" under my
/// latest read message, "Delivered" under my latest delivered one when newer,
/// "Sending" under my latest pending one; every failed one says so).
struct ReceiptHolders: Equatable {
    var read: String?
    var delivered: String?
    var sending: String?

    static func find(in window: TranscriptWindow, meID: String, readThrough: Int?) -> ReceiptHolders {
        var holders = ReceiptHolders()
        var index = window.count - 1
        while index >= 0 {
            let m = window[index]
            index -= 1
            guard m.authorID == meID, m.retractedAt == nil else { continue }
            if m.isPending {
                if holders.sending == nil, m.delivery == .sending { holders.sending = m.rowKey }
                continue
            }
            if let seq = m.seq, let readThrough, seq <= readThrough {
                holders.read = m.rowKey
                break
            }
            if holders.delivered == nil, m.delivery == .sent { holders.delivered = m.rowKey }
        }
        return holders
    }

    var keys: [String] { [read, delivered, sending].compactMap { $0 } }
}

/// Builds the rows of one message from its neighbours (groups, tails,
/// separators, receipts). Pure apart from the measurement cache.
enum RowDerivation {
    static func rows(at index: Int, in window: TranscriptWindow, holders: ReceiptHolders, context c: RowContext) -> [TranscriptRow] {
        let g = c.geometry
        let m = window[index]
        let prev = index > 0 ? window[index - 1] : nil
        let next = index + 1 < window.count ? window[index + 1] : nil
        let outgoing = m.authorID == c.meID
        let key = m.rowKey
        var rows: [TranscriptRow] = []

        let separated = prev.map { m.createdAt.timeIntervalSince($0.createdAt) > TranscriptGeometry.separatorWindow } ?? true
        var gap: CGFloat = 0
        if let prev, !separated {
            let sameGroup = prev.authorID == m.authorID && prev.retractedAt == nil
                && m.createdAt.timeIntervalSince(prev.createdAt) < TranscriptGeometry.groupWindow
            gap = sameGroup ? g.groupGap : g.senderGap
        }
        let lastOfGroup = next.map {
            $0.authorID != m.authorID || $0.retractedAt != nil
                || $0.createdAt.timeIntervalSince(m.createdAt) >= TranscriptGeometry.groupWindow
        } ?? true

        if separated {
            let day = c.strings.dayString(m.createdAt, now: c.now)
            let time = c.strings.timeString(m.createdAt)
            let width = c.measurer.labelWidth(day, size: g.captionSize, emphasized: true)
                + c.measurer.labelWidth(" " + time, size: g.captionSize, emphasized: false)
            rows.append(TranscriptRow(key: "sep:\(key)", kind: .separator(day: day, time: time), messageKey: key,
                                      gapBefore: index == 0 ? 0 : g.senderGap, height: g.separatorHeight,
                                      x: ((g.width - width) / 2).rounded(), width: width))
        }
        if m.retractedAt != nil {
            let text = c.strings.retracted
            let width = c.measurer.labelWidth(text, size: g.captionSize, emphasized: false)
            rows.append(TranscriptRow(key: key, kind: .retracted(text), messageKey: key, gapBefore: max(gap, g.labelGap),
                                      height: g.labelHeight, x: ((g.width - width) / 2).rounded(), width: width))
            return rows
        }
        let failed = if case .failed = m.delivery { true } else { false }
        for (partIndex, part) in m.parts.enumerated() {
            let measureKey = Measurer.key(m, part: partIndex, geometry: g)
            let measured = c.measurer.cached(measureKey)
            let size = measured ?? Measurer.estimate(part, geometry: g)
            let tail = lastOfGroup && partIndex == m.parts.count - 1
            let reactions = m.reactions.filter { $0.partIndex == partIndex }.map(\.kind)
            let kind: TranscriptRowKind = switch part {
            case .text(let text, let mentions):
                .bubble(outgoing: outgoing, text: text, mentions: mentions, tail: tail, reactions: reactions, failed: failed)
            case .work(let session, let status, let preview):
                .work(outgoing: outgoing, session: session, status: status, statusText: c.strings.workStatus(status),
                      preview: preview, tail: tail)
            case .fallback(let text):
                .fallback(outgoing: outgoing, text: text, tail: tail)
            }
            var row = TranscriptRow(key: "\(key)#\(partIndex)", kind: kind, messageKey: key,
                                    gapBefore: partIndex == 0 ? gap : g.groupGap, height: size.height,
                                    x: g.bubbleX(width: size.width, outgoing: outgoing), width: size.width,
                                    estimated: measured == nil, measureKey: measureKey)
            if !reactions.isEmpty { row.gapBefore += g.badgeRoom }
            rows.append(row)
        }
        if let label = receipt(for: m, holders: holders, context: c) {
            let width = c.measurer.labelWidth(label.text, size: g.captionSize, emphasized: true)
                + (label.detail.map { c.measurer.labelWidth(" " + $0, size: g.captionSize, emphasized: false) } ?? 0)
            let x = outgoing ? g.width - g.sideMargin - width : g.sideMargin
            rows.append(TranscriptRow(key: "rcpt:\(key)",
                                      kind: .label(text: label.text, detail: label.detail, outgoing: outgoing, tone: label.tone),
                                      messageKey: key, gapBefore: g.labelGap, height: g.labelHeight, x: x.rounded(), width: width))
        }
        return rows
    }

    private static func receipt(for m: HomeMessage, holders: ReceiptHolders, context c: RowContext)
        -> (text: String, detail: String?, tone: LabelTone)? {
        if case .failed = m.delivery {
            return (c.strings.notDelivered, c.strings.retryHint.isEmpty ? nil : c.strings.retryHint, .danger)
        }
        let key = m.rowKey
        if key == holders.read { return (c.strings.read, nil, .secondary) }
        if key == holders.delivered { return (c.strings.delivered, nil, .secondary) }
        if key == holders.sending { return (c.strings.sending, nil, .secondary) }
        return nil
    }

    static func typingRow(after last: HomeMessage?, context c: RowContext) -> TranscriptRow {
        let g = c.geometry
        let gap = last.map { $0.authorID == c.meID ? g.senderGap : g.groupGap } ?? 0
        let width = g.lineHeight * 2.6 + 2 * g.insetX / 2
        return TranscriptRow(key: "typing", kind: .typing, messageKey: nil, gapBefore: gap, height: g.typingHeight,
                             x: g.sideMargin, width: width.rounded())
    }
}
