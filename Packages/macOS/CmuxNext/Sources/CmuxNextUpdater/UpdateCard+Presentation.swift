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
        UpdateCardPresentation(title: "", detail: nil, progress: nil, buttons: [], accent: false)
    }
}

extension UpdateCardPresentation.Button {
    public var title: String { "" }
}
