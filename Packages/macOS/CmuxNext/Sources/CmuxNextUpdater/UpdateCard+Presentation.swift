import Foundation

/// The card's text (localized).
nonisolated public struct UpdateCardPresentation: Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var progress: Double?
}

extension UpdateCard {
    public var presentation: UpdateCardPresentation {
        switch self {
        case .checking:
            UpdateCardPresentation(title: UpdaterStrings.checking, detail: nil, progress: nil)
        case .downloading(let progress):
            UpdateCardPresentation(title: UpdaterStrings.downloading, detail: nil, progress: progress)
        case .note(let text, _):
            UpdateCardPresentation(title: text, detail: nil, progress: nil)
        }
    }
}

extension UpdateCard {
    /// A stable name for scripts (`updates.status.card.kind`).
    public var kind: String {
        switch self {
        case .checking: "checking"
        case .downloading: "downloading"
        case .note: "note"
        }
    }
}
