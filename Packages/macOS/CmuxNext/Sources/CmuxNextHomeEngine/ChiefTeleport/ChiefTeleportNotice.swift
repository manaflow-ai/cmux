public import Foundation

/// The Chief conversation's row about where the Chief runs (Home's notice row, under the newest
/// message): a move that runs ("Chief is moving to cmux Cloud…"), one that failed with the
/// engine's reason, the place it went and when ("Chief moved to cmux Cloud · 4:02 PM"), a
/// rollback ("Chief moved back to this Mac"), or its fork ("Chief forked to cmux Cloud as
/// “Chief fork” · 4:02 PM"). Pure: the marks and the phase in, the text out.
///
/// ```swift
/// ChiefTeleportNotice(marks: model.marks, phase: model.shownPhase, placeName: { "\($0)" }).text(timeZone: .current)
/// ```
public nonisolated struct ChiefTeleportNotice: Sendable {
    /// What the home's `state` folder says.
    public var marks: ChiefHomeMarks
    /// The move to show (``ChiefTeleportModel/shownPhase``).
    public var phase: ChiefTeleportPhase
    /// A place's name as the menu says it.
    public var placeName: @Sendable (ChiefLocation) -> String

    public init(marks: ChiefHomeMarks, phase: ChiefTeleportPhase, placeName: @escaping @Sendable (ChiefLocation) -> String) {
        self.marks = marks
        self.phase = phase
        self.placeName = placeName
    }

    /// The row's text; nil when the Chief runs here with no move, failure or fork to tell.
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
        case .rolledBack:
            if marks.whereabouts.location == .thisMac { return ChiefTeleportStrings.noticeMovedBack }
        case .idle, .done:
            break
        }
        let location = marks.whereabouts.location
        if location != .thisMac {
            return ChiefTeleportStrings.noticeMoved(placeName(location), at: marks.movedAt.map { Self.time($0, timeZone) })
        }
        if let fork = marks.fork {
            return ChiefTeleportStrings.noticeForked(fork.name, at: fork.at.map { Self.time($0, timeZone) })
        }
        return nil
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
