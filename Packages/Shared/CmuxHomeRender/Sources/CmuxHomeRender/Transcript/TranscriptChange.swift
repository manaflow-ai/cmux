import CmuxHomeCore
import Foundation

/// What one transcript update did, which decides how it animates.
enum TranscriptChange: Equatable {
    /// The first rows: no animation, pinned to the newest row.
    case initial
    /// An older page above the loaded rows: no animation, the viewport keeps its rows.
    case prepend
    /// One of my messages appeared at the end (the send morph when it came from the field).
    case send(IdempotencyKey)
    /// Someone else's message appeared at the end.
    case receive
    case typing(Bool)
    /// A send was committed or refused (receipts change).
    case delivery
    /// Another participant read further.
    case read
    /// Anything else: reactions, retractions, a resend, a window refetch.
    case other
    /// Only the compose field changed height (`send`: it emptied on send).
    case field(send: Bool)

    /// The spring the rows that move follow.
    var element: SpringElement {
        switch self {
        case .initial, .prepend, .send, .other: HomeMotion.send
        case .receive: HomeMotion.receive
        case .typing(let on): on ? HomeMotion.typing : HomeMotion.receive
        case .delivery: HomeMotion.delivered
        case .read: HomeMotion.read
        case .field(let send): send ? HomeMotion.fieldTop : HomeMotion.fieldGrow
        }
    }

    /// Whether the change animates at all (initial loads and pages do not).
    var animates: Bool {
        switch self {
        case .initial, .prepend: false
        default: true
        }
    }

    static func classify(old: [TranscriptItem], new: [TranscriptItem], me: ParticipantID,
                         typing: (old: Bool, new: Bool), read: (old: Seq?, new: Seq?)) -> TranscriptChange {
        if old.isEmpty { return new.isEmpty ? (typing.old != typing.new ? .typing(typing.new) : .other) : .initial }
        let oldKeys = Set(old.map(\.key))
        if let firstOld = old.first?.key, let k = new.firstIndex(where: { $0.key == firstOld }), k > 0,
           new[..<k].allSatisfy({ !oldKeys.contains($0.key) }) {
            return .prepend
        }
        let lastOldIndex = new.lastIndex { oldKeys.contains($0.key) } ?? -1
        let appended = new.suffix(from: lastOldIndex + 1).filter { !oldKeys.contains($0.key) }
        if let mine = appended.last(where: { $0.author == me }) { return .send(mine.key) }
        if !appended.isEmpty { return .receive }
        if typing.old != typing.new { return .typing(typing.new) }
        let oldDelivery = Dictionary(old.map { ($0.key, $0.delivery) }, uniquingKeysWith: { a, _ in a })
        if new.contains(where: { item in oldDelivery[item.key].map { $0 != item.delivery } ?? false }) { return .delivery }
        if read.old != read.new { return .read }
        return .other
    }
}
