public import CoreGraphics

/// Tone of a small label row (receipts, errors).
nonisolated enum LabelTone: Hashable, Sendable {
    case secondary
    case danger
}

/// What one transcript row shows. Everything here is derived
/// (MessagesLab MODEL.md "Derived"): groups, tails, separators, receipts.
nonisolated enum TranscriptRowKind: Hashable, Sendable {
    /// Time separator: a bold day and a regular time ("Today 12:06 PM").
    case separator(day: String, time: String)
    case bubble(outgoing: Bool, text: String, mentions: [HomeMention], tail: Bool, reactions: [String], failed: Bool, markdown: Bool)
    case work(outgoing: Bool, session: String, status: HomeWorkStatus, statusText: String, preview: String?, tail: Bool)
    /// A part the renderer does not draw, as a muted one-line bubble.
    case fallback(outgoing: Bool, text: String, tail: Bool)
    /// A receipt or status line under a message ("Read 9:41", "Not delivered").
    case label(text: String, detail: String?, outgoing: Bool, tone: LabelTone)
    case retracted(String)
    case typing
}

/// One row of the transcript: its kind and its frame inputs (points).
nonisolated struct TranscriptRow: Hashable, Sendable {
    /// Stable identity: built from the message's row key, so a pending
    /// message keeps its row (and its layer) when it is confirmed.
    var key: String
    var kind: TranscriptRowKind
    /// Row key of the message this row belongs to.
    var messageKey: String?
    var gapBefore: CGFloat
    var height: CGFloat
    var x: CGFloat
    var width: CGFloat
    /// The size is an estimate; measured before it comes near the viewport.
    var estimated = false
    var measureKey: MeasureKey?

    var isBubbleLike: Bool {
        switch kind {
        case .bubble, .work, .fallback: true
        default: false
        }
    }

    var isOutgoing: Bool {
        switch kind {
        case .bubble(let outgoing, _, _, _, _, _, _), .work(let outgoing, _, _, _, _, _), .label(_, _, let outgoing, _),
             .fallback(let outgoing, _, _): outgoing
        default: false
        }
    }

    /// The message part a bubble-like row draws (re-measurement).
    var part: HomePart? {
        switch kind {
        case .bubble(_, let text, let mentions, _, _, _, let markdown): markdown ? .markdown(text) : .text(text, mentions: mentions)
        case .work(_, let session, let status, _, let preview, _): .work(session: session, status: status, preview: preview)
        case .fallback(_, let text, _): .fallback(text)
        default: nil
        }
    }

    /// What the drawing depends on (not `x`, not the gap): equal signatures reuse a raster.
    var drawSignature: DrawSignature { DrawSignature(kind: kind, width: width, height: height) }
}
