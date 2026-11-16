public import Foundation

/// The Chief conversation's row about where the Chief runs (Home's notice row, under the newest
/// message): a move that runs ("Chief is moving to cmux Cloud…"), one that failed with the
/// engine's reason, or, once, an event the app saw happen (``ChiefTeleportAnnouncement``): the
/// place it went and when ("Chief moved to cmux Cloud · 4:02 PM"), a rollback ("Chief moved back
/// to this Mac"), or a fork ("Chief forked to cmux Cloud as “Chief fork” · 4:02 PM"). Pure: the
/// phase and the event in, the text out.
///
/// ```swift
/// ChiefTeleportNotice(phase: model.shownPhase, announcement: model.announcement, placeName: { "\($0)" }).text(timeZone: .current)
/// ```
public nonisolated struct ChiefTeleportNotice: Sendable {
    /// The move to show (``ChiefTeleportModel/shownPhase``).
    public var phase: ChiefTeleportPhase
    /// The event to announce once (``ChiefTeleportModel/announcement``).
    public var announcement: ChiefTeleportAnnouncement?
    /// A place's name as the menu says it.
    public var placeName: @Sendable (ChiefLocation) -> String

    public init(phase: ChiefTeleportPhase, announcement: ChiefTeleportAnnouncement?, placeName: @escaping @Sendable (ChiefLocation) -> String) {
        self.phase = phase
        self.announcement = announcement
        self.placeName = placeName
    }

    /// The row's text: a running or failed move, else the event; nil when there is none.
    ///
    /// - Parameter timeZone: The zone the times read in (the person's).
    public func text(timeZone: TimeZone) -> String? {
        switch phase {
        case .checking(let name), .moving(let name), .verifying(let name):
            return ChiefTeleportStrings.noticeMoving(name)
        case .rollingBack:
            return ChiefTeleportStrings.noticeMovingBack
        case .failed(let name, let reason):
            return ChiefTeleportStrings.noticeFailed(name, reason: Self.firstLine(reason))
        case .idle, .done, .rolledBack:
            break
        }
        switch announcement {
        case .moved(let place, let at):
            return ChiefTeleportStrings.noticeMoved(placeName(place), at: at.map { Self.time($0, timeZone) })
        case .movedBack:
            return ChiefTeleportStrings.noticeMovedBack
        case .forked(let name, let at):
            return ChiefTeleportStrings.noticeForked(name, at: at.map { Self.time($0, timeZone) })
        case nil:
            return nil
        }
    }

    /// "4:02 PM" today, "Nov 5, 4:02 PM" another day.
    static func time(_ date: Date, _ timeZone: TimeZone, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = calendar.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle(date: .omitted, time: .shortened)
            : Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The engine's reason up to its first line (a row, not a log).
    private static func firstLine(_ reason: String) -> String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        return line.trimmingCharacters(in: .whitespaces)
    }
}
