import Foundation

/// The card's text and buttons (localized).
nonisolated public struct UpdateCardPresentation: Equatable, Sendable {
    public enum Button: String, Sendable { case installNow, later }
    public var title: String
    public var detail: String?
    public var progress: Double?
    public var buttons: [Button]
}

extension UpdateCard {
    public var presentation: UpdateCardPresentation {
        switch self {
        case .checking:
            UpdateCardPresentation(title: UpdaterStrings.checking, detail: nil, progress: nil, buttons: [])
        case .downloading(let progress):
            UpdateCardPresentation(title: UpdaterStrings.downloading, detail: nil, progress: progress, buttons: [])
        case .waiting(_, let busyAgents):
            UpdateCardPresentation(title: UpdaterStrings.cardWaitingTitle, detail: UpdaterStrings.cardWaitingDetail(busyAgents),
                                   progress: nil, buttons: [.installNow, .later])
        case .installing:
            UpdateCardPresentation(title: UpdaterStrings.installing, detail: nil, progress: nil, buttons: [])
        case .note(let text, _):
            UpdateCardPresentation(title: text, detail: nil, progress: nil, buttons: [])
        }
    }
}

extension UpdateCardPresentation.Button {
    public var title: String {
        switch self {
        case .installNow: UpdaterStrings.installNow
        case .later: UpdaterStrings.later
        }
    }
}

extension UpdateCard {
    /// A stable name for scripts (`updates.status.card.kind`).
    public var kind: String {
        switch self {
        case .checking: "checking"
        case .downloading: "downloading"
        case .waiting: "waiting"
        case .installing: "installing"
        case .note: "note"
        }
    }
}
