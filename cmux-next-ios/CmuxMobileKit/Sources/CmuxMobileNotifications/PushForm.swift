import Foundation

/// The long-press view's state for one notification (the content extension):
/// which option rows a question or permission shows, what is chosen, and the
/// reply that Submit, a row or the composer sends. No UI here, so it is tested
/// on its own (`PushFormTests`).
public struct PushForm: Sendable, Equatable {
    /// One tappable row.
    public struct Row: Sendable, Equatable, Identifiable {
        public enum Style: Sendable, Equatable {
            /// A single-choice option: a tap sends it.
            case choice
            /// A multi-select option: a tap toggles its checkbox.
            case checkbox
            /// A permission option: a tap sends it.
            case allow, deny
        }

        public var id: String
        public var question: Int
        public var label: String
        public var detail: String?
        public var style: Style
    }

    public let payload: PushPayload
    /// Per question, the chosen option labels.
    public private(set) var selected: [Set<String>]
    /// Per question, the "Other" text.
    public var other: [String]

    public init(payload: PushPayload) {
        self.payload = payload
        selected = Array(repeating: [], count: payload.questions.count)
        other = Array(repeating: "", count: payload.questions.count)
    }

    /// Whether a tap on a choice row sends at once: one single-choice question.
    public var sendsOnTap: Bool {
        payload.questions.count == 1 && payload.questions.first?.multiSelect == false
    }

    /// The rows to draw, in order.
    public var rows: [Row] {
        switch payload.kind {
        case .question:
            return payload.questions.enumerated().flatMap { q, question in
                question.options.enumerated().map { i, option in
                    Row(id: "q\(q).\(i)", question: q, label: option.label, detail: option.description,
                        style: question.multiSelect || !sendsOnTap ? .checkbox : .choice)
                }
            }
        case .permission:
            // The Feed's options (`PushPayload.phoneOptions`).
            return payload.phoneOptions.compactMap { option in
                if option.isAllow { return Row(id: option.id, question: 0, label: option.label, detail: nil, style: .allow) }
                if option.isReject { return Row(id: option.id, question: 0, label: option.label, detail: nil, style: .deny) }
                return nil
            }
        default:
            return []
        }
    }

    /// Whether question `q` takes free text.
    public func allowsOther(_ q: Int) -> Bool {
        payload.questions.indices.contains(q) && payload.questions[q].allowsOther
    }

    public func isSelected(_ row: Row) -> Bool {
        selected.indices.contains(row.question) && selected[row.question].contains(row.label)
    }

    /// A tap on `row`: the reply to send now, or nil when it only changed the selection.
    public mutating func tap(_ row: Row) -> PushReply.Action? {
        switch row.style {
        case .allow: return .allow(optionID: row.id)
        case .deny: return .deny(optionID: row.id)
        case .choice:
            guard let index = payload.questions.first?.options.firstIndex(where: { $0.label == row.label }) else { return nil }
            return .option(index, label: row.label)
        case .checkbox:
            guard selected.indices.contains(row.question) else { return nil }
            let multi = payload.questions[row.question].multiSelect
            if selected[row.question].contains(row.label) {
                selected[row.question].remove(row.label)
            } else {
                if !multi { selected[row.question].removeAll() }
                selected[row.question].insert(row.label)
            }
            return nil
        }
    }

    /// Submit is offered: a question that is not sent by one tap, or has free text.
    public var showsSubmit: Bool {
        payload.kind == .question && !payload.questions.isEmpty && (!sendsOnTap || payload.questions.contains(where: \.allowsOther))
    }

    /// Every question has an answer (a chosen option or text).
    public var canSubmit: Bool {
        guard !payload.questions.isEmpty else { return false }
        return payload.questions.indices.allSatisfy { q in
            !selected[q].isEmpty || !other[q].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Submit's reply: each question's chosen labels in option order, and its text.
    public var answers: PushReply.Action? {
        guard canSubmit else { return nil }
        let chosen = payload.questions.enumerated().map { q, question in
            question.options.map(\.label).filter { selected[q].contains($0) }
        }
        return .answers(selected: chosen, other: other.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    /// The composer: shown for every kind that takes text. A question's
    /// composer answers with free text ("Other"), a permission has none.
    public var hasComposer: Bool {
        switch payload.kind {
        case .permission: false
        case .question: payload.questions.count <= 1 && (payload.questions.first?.allowsOther ?? true)
        case .completed, .failed, .chief: true
        // Text into a terminal from a notification waits for the #13742 decision (PR B).
        case .terminal: false
        }
    }

    /// The composer's reply for `text` and `attachments` (file names in the outbox).
    public func composerReply(_ text: String, attachments: [String]) -> PushReply.Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
        if payload.kind == .question {
            guard !trimmed.isEmpty else { return nil }
            // One question (or none listed): the text is its "Other" answer.
            return .answers(selected: [[]], other: [trimmed])
        }
        return .text(trimmed, attachments: attachments)
    }

    /// Whether the content may show: always with previews on; with them off
    /// only while the phone is unlocked (`PushProtectedMarker`).
    public static func showsContent(previews: Bool, unlocked: Bool) -> Bool {
        previews || unlocked
    }

    /// The saved chat (which holds the person's own messages) loads only while
    /// the phone is unlocked, whatever Show previews says (PR #24156 review L1).
    public static func loadsSnapshot(unlocked: Bool) -> Bool {
        unlocked
    }
}

/// Whether protected data is available (the phone is unlocked), for an
/// extension, which has no `UIApplication`: a small file with complete
/// protection can be written and read only while the phone is unlocked.
public struct PushProtectedMarker: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("unlocked.marker")
    }

    /// True while the phone is unlocked.
    public func isUnlocked() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            do { try Data("1".utf8).write(to: url, options: options) } catch { return false }
        }
        return (try? Data(contentsOf: url)) != nil
    }
}
