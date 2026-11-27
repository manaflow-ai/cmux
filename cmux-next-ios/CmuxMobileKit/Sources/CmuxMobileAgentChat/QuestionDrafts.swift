import CmuxAgentQuestion
import Foundation

/// A partly answered question (Feed or chat), kept across relaunches: the page the person
/// was on, the options they picked and any Other text, per question id.
public struct QuestionDraft: Codable, Hashable, Sendable {
    public var activeItem: Int
    public var chosen: [String: [String]]
    public var other: [String: String]

    public init(activeItem: Int = 0, chosen: [String: [String]] = [:], other: [String: String] = [:]) {
        self.activeItem = activeItem
        self.chosen = chosen
        self.other = other
    }

    public init(_ state: AgentQuestionCardState) {
        activeItem = state.activeItem
        chosen = state.chosen.mapValues { $0.sorted() }.filter { !$0.value.isEmpty }
        other = state.otherDrafts.filter { !$0.value.isEmpty }
    }

    public var isEmpty: Bool { activeItem == 0 && chosen.isEmpty && other.isEmpty }

    /// Rebuilds the card state by replaying reducer inputs that never advance or submit
    /// (`toggle` on a highlighted row, Other text, paging).
    public func restore(into question: AgentQuestion) -> AgentQuestionCardState {
        var state = AgentQuestionCardState(question: question)
        guard question.isPending else { return state }
        for (index, item) in question.items.enumerated() {
            while state.activeItem < index { _ = state.send(.nextItem) }
            guard state.activeItem == index else { break }
            for optionID in chosen[item.id] ?? [] {
                guard let row = item.options.firstIndex(where: { $0.id == optionID }) else { continue }
                for _ in 0..<state.rowCount(item) { _ = state.send(.up) }
                for _ in 0..<row { _ = state.send(.down) }
                _ = state.send(.toggle)
            }
            if let text = other[item.id], item.allowsOther { _ = state.send(.otherText(text)) }
        }
        let target = min(max(activeItem, 0), max(question.items.count - 1, 0))
        while state.activeItem > target { _ = state.send(.previousItem) }
        while state.activeItem < target { _ = state.send(.nextItem) }
        return state
    }
}

/// Saved question drafts, a small JSON file in Application Support.
@MainActor
public final class QuestionDraftStore {
    public static let shared = QuestionDraftStore(url: QuestionDraftStore.defaultURL)
    public let url: URL
    private var drafts: [String: QuestionDraft]
    /// The most drafts kept (oldest questions are answered or gone).
    static let limit = 100
    private var order: [String]

    public init(url: URL) {
        self.url = url
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        drafts = saved?.drafts ?? [:]
        order = saved?.order ?? []
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Questions", directoryHint: .isDirectory).appending(path: "drafts.json")
    }

    public func draft(for questionID: String) -> QuestionDraft? { drafts[questionID] }

    public func save(_ draft: QuestionDraft, for questionID: String) {
        guard drafts[questionID] != draft else { return }
        if draft.isEmpty {
            drafts[questionID] = nil
            order.removeAll { $0 == questionID }
        } else {
            drafts[questionID] = draft
            order.removeAll { $0 == questionID }
            order.append(questionID)
            while order.count > Self.limit { drafts[order.removeFirst()] = nil }
        }
        write()
    }

    /// An answered or cancelled question needs no draft.
    public func clear(_ questionID: String) {
        guard drafts[questionID] != nil else { return }
        drafts[questionID] = nil
        order.removeAll { $0 == questionID }
        write()
    }

    private struct Saved: Codable {
        var drafts: [String: QuestionDraft]
        var order: [String]
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(Saved(drafts: drafts, order: order)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
