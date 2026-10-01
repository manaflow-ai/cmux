import CmuxConversation
import Foundation

/// One transcript row, flattened from ``ConversationState`` for the table.
struct TranscriptRow: Equatable {
    enum Style: Equatable {
        case user, assistant, reasoning, activity, approval, notice, error, separator
    }

    var id: String
    var style: Style
    var text: String
    /// A status line under the bubble (delivery, activity state).
    var status: String?
    /// Attachments: (upload id, display line, missing or failed).
    var files: [(String, String, Bool)]
    var clientMessageID: ClientMessageID?
    var delivery: DeliveryState?
    var approval: ApprovalRequest?

    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.id == b.id && a.text == b.text && a.status == b.status && a.delivery == b.delivery && a.approval == b.approval
            && a.files.map(\.1) == b.files.map(\.1) && a.files.map(\.2) == b.files.map(\.2)
    }

    /// Rows for a state.
    static func rows(_ state: ConversationState) -> [TranscriptRow] {
        state.items.compactMap { row($0, state) }
    }

    private static func fileLine(_ a: ConversationAttachment) -> (String, String, Bool) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
        switch a.state {
        case let .uploading(received):
            let pct = a.size == 0 ? 100 : Int(Double(received) / Double(a.size) * 100)
            return (a.uploadID, "\(a.name) (\(size)) \(pct)%", false)
        case .uploaded:
            return (a.uploadID, "\(a.name) (\(size))", false)
        case .failed:
            return (a.uploadID, "(!) \(a.name) (\(size))", true)
        case .missing:
            return (a.uploadID, "\(a.name) \u{2014} \(ConversationStrings.fileMissing)", true)
        }
    }

    private static func row(_ item: ConversationItem, _ state: ConversationState) -> TranscriptRow? {
        switch item.kind {
        case let .message(m):
            let files = m.attachmentIDs.compactMap { state.attachments[$0] }.map(fileLine)
            var status: String?
            switch m.delivery {
            case .sending?: status = ConversationStrings.sending
            case let .queued(position)?: status = ConversationStrings.queued(position)
            case .uploading?: status = ConversationStrings.uploading
            case .failed?: status = ConversationStrings.failed
            case .steered?: status = ConversationStrings.steered
            default: status = nil
            }
            return TranscriptRow(id: item.id, style: m.role == .user ? .user : .assistant, text: m.text, status: status, files: files, clientMessageID: m.clientMessageID, delivery: m.delivery, approval: nil)
        case let .reasoning(t):
            return TranscriptRow(id: item.id, style: .reasoning, text: t, status: nil, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case let .activity(a):
            return TranscriptRow(id: item.id, style: .activity, text: a.title, status: a.status, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case let .plan(entries):
            let text = entries.map { "[\($0.status == "completed" ? "x" : " ")] \($0.content)" }.joined(separator: "\n")
            return TranscriptRow(id: item.id, style: .activity, text: text, status: nil, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case let .approval(r):
            return TranscriptRow(id: item.id, style: .approval, text: r.title, status: r.decision, files: [], clientMessageID: nil, delivery: nil, approval: r)
        case let .notice(t):
            return TranscriptRow(id: item.id, style: .notice, text: t, status: nil, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case let .error(t):
            return TranscriptRow(id: item.id, style: .error, text: t, status: nil, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case let .extension(x):
            return TranscriptRow(id: item.id, style: .notice, text: "\(x.namespace): \(x.type)", status: nil, files: [], clientMessageID: nil, delivery: nil, approval: nil)
        case .turnEnded:
            return nil
        }
    }
}
