import Foundation

/// The card's text and buttons (localized).
nonisolated public struct UpdateCardPresentation: Equatable, Sendable {
    public enum Button: String, Sendable { case installNow, later }
    public var title: String
    public var detail: String?
    public var progress: Double?
    public var buttons: [Button]
    /// A staged update: the accent look.
    public var accent: Bool
}

extension UpdateCard {
    public var presentation: UpdateCardPresentation {
        switch self {
        case .checking:
            UpdateCardPresentation(title: UpdaterStrings.checking, detail: nil, progress: nil, buttons: [], accent: false)
        case .downloading(let progress):
            UpdateCardPresentation(title: UpdaterStrings.downloading, detail: nil, progress: progress, buttons: [], accent: false)
        case .available(let version):
            UpdateCardPresentation(title: UpdaterStrings.availableNoVersion,
                                   detail: version.map(UpdaterStrings.cardAvailableDetail), progress: nil, buttons: [], accent: true)
        case .ready(let version):
            UpdateCardPresentation(title: UpdaterStrings.restartToUpdate,
                                   detail: version.map(UpdaterStrings.cardReadyDetail) ?? UpdaterStrings.cardReadyDetailNoVersion,
                                   progress: nil, buttons: [], accent: true)
        case .waiting(_, let busyAgents):
            UpdateCardPresentation(title: UpdaterStrings.cardWaitingTitle, detail: UpdaterStrings.cardWaitingDetail(busyAgents),
                                   progress: nil, buttons: [.installNow, .later], accent: false)
        case .installing:
            UpdateCardPresentation(title: UpdaterStrings.installing, detail: nil, progress: nil, buttons: [], accent: false)
        case .note(let text, _):
            UpdateCardPresentation(title: text, detail: nil, progress: nil, buttons: [], accent: false)
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
