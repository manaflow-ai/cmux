public import Foundation

/// The semantic calendar day represented by a notification-feed section.
public enum NotificationFeedDay: Equatable, Sendable {
    /// The calendar day containing the grouping policy's injected `now`.
    case today
    /// The calendar day immediately before today.
    case yesterday
    /// An earlier calendar day, represented by its start-of-day date.
    case older(Date)
}
