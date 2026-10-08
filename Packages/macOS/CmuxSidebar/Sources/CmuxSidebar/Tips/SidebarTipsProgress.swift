public import Foundation

/// What the user has seen of the tips, persisted per Mac.
public struct SidebarTipsProgress: Equatable, Sendable {
    /// The currently selected tip.
    public var currentTipID: String?
    /// Tips already offered or selected by the user.
    public var seenTipIDs: Set<String>
    /// Local calendar day (`yyyy-MM-dd`) the Tips popover was last opened.
    /// `nil` until the first open.
    public var lastOpenedDay: String?
    /// Whether automatic tips are disabled. Manual viewing remains available.
    public var automaticTipsDisabled: Bool
    /// The last presentation time, for daily discovery and weekly refreshers.
    public var lastOpenedAt: Date?

    /// Creates progress, defaulting to an unseen catalog with reminders enabled.
    public init(
        currentTipID: String? = nil,
        seenTipIDs: Set<String> = [],
        lastOpenedDay: String? = nil,
        automaticTipsDisabled: Bool = false,
        lastOpenedAt: Date? = nil
    ) {
        self.currentTipID = currentTipID
        self.seenTipIDs = seenTipIDs
        self.lastOpenedDay = lastOpenedDay
        self.automaticTipsDisabled = automaticTipsDisabled
        self.lastOpenedAt = lastOpenedAt
    }
}
