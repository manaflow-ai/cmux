import Foundation

/// One run of events of the same local day in the Feed: a table section with
/// a day label above it ("Yesterday", "Saturday", "Nov 12").
struct FeedDaySection: Hashable, Sendable {
    /// The day's first instant in the calendar's time zone.
    var day: Date
    /// 0, unless the list shows the same day in more than one run (events out of
    /// time order): the diffable source refuses a repeated section.
    var run = 0

    /// The whole Feed as one section with no label (day separators off).
    static let undated = FeedDaySection(day: .distantPast)

    /// The pinned group (the whole Feed's open asks, first): a section of its own ahead of the
    /// days, with no day label (the header's "Needs you" row names it).
    static let pinned = FeedDaySection(day: .distantFuture)
}

/// A day section and its events, in the list's order.
struct FeedDayGroup: Equatable, Sendable {
    var section: FeedDaySection
    var ids: [String]
}

/// Finds the local day of a date. Events arrive newest first, so most fall in
/// the day of the one before: that day's interval is kept and the calendar is
/// asked once per day, not once per event.
struct FeedDayBucketer {
    let calendar: Calendar
    private var cached: DateInterval?

    init(calendar: Calendar) { self.calendar = calendar }

    /// The first instant of `date`'s day (a day with a clock change is 23 or 25 hours long).
    mutating func day(of date: Date) -> Date {
        if let cached, date >= cached.start, date < cached.end { return cached.start }
        let interval = calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
        cached = interval
        return interval.start
    }
}

enum FeedDays {
    /// `rows` (the list's order) as runs of the same local day.
    static func groups(_ rows: some Sequence<(id: String, date: Date)>, calendar: Calendar) -> [FeedDayGroup] {
        groups(carrying: rows.lazy.map { (id: $0.id, date: Optional($0.date)) }, calendar: calendar)
    }

    /// The same, with rows that have no time of their own (date nil: a stack's fold line): each
    /// stays in the day of the row before it.
    static func groups(carrying rows: some Sequence<(id: String, date: Date?)>, calendar: Calendar) -> [FeedDayGroup] {
        var bucketer = FeedDayBucketer(calendar: calendar)
        var groups: [FeedDayGroup] = []
        var runs: [Date: Int] = [:]
        for row in rows {
            // A first row with no time has no row to follow: it opens the list in no day.
            let day = row.date.map { bucketer.day(of: $0) } ?? groups.last?.section.day ?? FeedDaySection.undated.day
            if let last = groups.indices.last, groups[last].section.day == day {
                groups[last].ids.append(row.id)
            } else {
                let run = runs[day, default: 0]
                runs[day] = run + 1
                groups.append(FeedDayGroup(section: FeedDaySection(day: day, run: run), ids: [row.id]))
            }
        }
        return groups
    }

    /// The same, with the list's first `pinned` rows (the open asks) in the pinned section ahead
    /// of the days: they are out of time order, so they join no day.
    static func groups(carrying rows: [(id: String, date: Date?)], pinned: Int, calendar: Calendar) -> [FeedDayGroup] {
        let count = min(max(pinned, 0), rows.count)
        let days = groups(carrying: rows[count...], calendar: calendar)
        guard count > 0 else { return days }
        return [FeedDayGroup(section: .pinned, ids: rows[..<count].map { $0.id })] + days
    }

    /// Whether a day section shows its label: every one but today's at the top
    /// of the list (the newest events need no "Today" above them).
    static func showsLabel(_ section: FeedDaySection, isFirst: Bool, today: Date) -> Bool {
        guard section != .undated, section != .pinned else { return false }
        return !(isFirst && section.day == today)
    }
}

/// How a day is named, relative to today.
enum FeedDayName: Equatable {
    case today, yesterday
    /// The last week: the weekday alone names the day.
    case weekday
    /// Older (or a day after today, a clock that is off): the date; with its year when that is not this year.
    case date(year: Bool)

    init(day: Date, today: Date, calendar: Calendar) {
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? .max
        switch days {
        case 0: self = .today
        case 1: self = .yesterday
        // Six days back: seven would be today's own weekday.
        case 2...6: self = .weekday
        default: self = .date(year: calendar.component(.year, from: day) != calendar.component(.year, from: today))
        }
    }
}

/// The day labels' text, from the system's formatters in the person's
/// language and region. Kept by the list (formatters are costly to make).
final class FeedDayLabeler {
    let calendar: Calendar
    private let relative = RelativeDateTimeFormatter()
    private let weekday = DateFormatter()
    private let shortDate = DateFormatter()
    private let datedYear = DateFormatter()

    init(calendar: Calendar, locale: Locale) {
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
        relative.calendar = calendar
        relative.locale = locale
        relative.dateTimeStyle = .named
        relative.formattingContext = .beginningOfSentence
        for (formatter, template) in [(weekday, "EEEE"), (shortDate, "MMMd"), (datedYear, "yMMMd")] {
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.formattingContext = .beginningOfSentence
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
    }

    /// "Today", "Yesterday", "Saturday", "Nov 12", "Nov 12, 2025".
    func text(day: Date, today: Date) -> String {
        let text = switch FeedDayName(day: day, today: today, calendar: calendar) {
        case .today: relative.localizedString(from: DateComponents(day: 0))
        case .yesterday: relative.localizedString(from: DateComponents(day: -1))
        case .weekday: weekday.string(from: day)
        case .date(let year): (year ? datedYear : shortDate).string(from: day)
        }
        // A label standing alone starts with a capital in every language that has them
        // ("today" and weekdays are lowercase mid-sentence in many).
        return text.prefix(1).capitalized(with: calendar.locale) + text.dropFirst()
    }
}

/// Inserts and removals that turn one grouped list into another, when the
/// events both keep stay in the same order and the same day section (a live
/// event, a done swipe); nil when they do not (a re-sort, a time zone change),
/// so the list rebuilds its sections instead.
struct FeedDayEdit: Equatable {
    var removed: [String]
    /// Sections the list did not have, each after `after` (nil: first, after the chips).
    var addedSections: [AddedSection]
    /// New rows, each group before a row that was already in its section, or at its section's end.
    var inserts: [Insert]
    /// Sections left with no rows.
    var removedSections: [FeedDaySection]

    struct AddedSection: Equatable {
        var section: FeedDaySection
        var after: FeedDaySection?
    }

    struct Insert: Equatable {
        var ids: [String]
        var section: FeedDaySection
        /// nil: at the section's end.
        var before: String?
    }

    init?(old: [FeedDayGroup], new: [FeedDayGroup]) {
        guard let rows = FeedSnapshotEdit(old: old.flatMap(\.ids), new: new.flatMap(\.ids)) else { return nil }
        var oldSection: [String: FeedDaySection] = [:]
        for group in old { for id in group.ids { oldSection[id] = group.section } }
        let oldSections = Set(old.map(\.section)), newSections = Set(new.map(\.section))
        // Sections both keep stay in the same order (they hold kept rows in order, or the list re-sorted).
        guard old.map(\.section).filter(newSections.contains) == new.map(\.section).filter(oldSections.contains) else { return nil }
        removed = rows.removed
        addedSections = []
        inserts = []
        var previous: FeedDaySection?
        for group in new {
            if !oldSections.contains(group.section) { addedSections.append(AddedSection(section: group.section, after: previous)) }
            previous = group.section
            var buffer: [String] = []
            for id in group.ids {
                if let was = oldSection[id] {
                    // A kept row in another day's section (its time changed): rebuild.
                    guard was == group.section else { return nil }
                    if !buffer.isEmpty { inserts.append(Insert(ids: buffer, section: group.section, before: id)); buffer = [] }
                } else {
                    buffer.append(id)
                }
            }
            if !buffer.isEmpty { inserts.append(Insert(ids: buffer, section: group.section, before: nil)) }
        }
        removedSections = old.map(\.section).filter { !newSections.contains($0) }
    }
}

/// An ask's move out of (or into) the pinned section to its place in its day (`FeedMoveEdit`
/// across sections), with the inserts, removals and sections beside it; nil when any other row
/// changes place or day, or too many move at once, so the list rebuilds its sections instead.
struct FeedDayMoveEdit: Equatable {
    enum Step: Equatable {
        /// Put a shown row in `section`, before `before` (nil: at the section's end).
        case move(String, section: FeedDaySection, before: String?)
        /// Put a new row in `section`, before `before` (nil: at the section's end).
        case insert(String, section: FeedDaySection, before: String?)
    }

    var removed: [String]
    /// Sections the list did not have (the day an answered ask goes to, the pinned group again).
    var addedSections: [FeedDayEdit.AddedSection]
    /// Each section's from its last row to its first: a step's `before` row is already in its place.
    var steps: [Step]
    /// Sections left with no rows (the pinned group once its last ask is answered).
    var removedSections: [FeedDaySection]

    init?(old: [FeedDayGroup], new: [FeedDayGroup], movers: Set<String>, limit: Int = 4) {
        let oldIDs = old.flatMap(\.ids), newIDs = new.flatMap(\.ids)
        guard let rows = FeedMoveEdit(old: oldIDs, new: newIDs, movers: movers, limit: limit) else { return nil }
        let oldSet = Set(oldIDs), newSet = Set(newIDs)
        let moving = movers.filter { oldSet.contains($0) && newSet.contains($0) }
        var oldSection: [String: FeedDaySection] = [:]
        for group in old { for id in group.ids { oldSection[id] = group.section } }
        let oldSections = Set(old.map(\.section)), newSections = Set(new.map(\.section))
        guard old.map(\.section).filter(newSections.contains) == new.map(\.section).filter(oldSections.contains) else { return nil }
        removed = rows.removed
        addedSections = []
        steps = []
        var previous: FeedDaySection?
        for group in new {
            if !oldSections.contains(group.section) { addedSections.append(.init(section: group.section, after: previous)) }
            previous = group.section
            var before: String?
            for id in group.ids.reversed() {
                if moving.contains(id) {
                    steps.append(.move(id, section: group.section, before: before))
                } else if let was = oldSection[id] {
                    // A row that stays put changed day (its time moved): rebuild.
                    guard was == group.section else { return nil }
                } else {
                    steps.append(.insert(id, section: group.section, before: before))
                }
                before = id
            }
        }
        removedSections = old.map(\.section).filter { !newSections.contains($0) }
    }

    /// The edit applied to `old` (what the list does to its snapshot).
    func applied(to old: [FeedDayGroup]) -> [FeedDayGroup] {
        let gone = Set(removed)
        var groups = old.map { FeedDayGroup(section: $0.section, ids: $0.ids.filter { !gone.contains($0) }) }
        for added in addedSections {
            let index = added.after.flatMap { after in groups.firstIndex { $0.section == after } }.map { $0 + 1 } ?? 0
            groups.insert(FeedDayGroup(section: added.section, ids: []), at: index)
        }
        func place(_ id: String, in section: FeedDaySection, before: String?) {
            guard let g = groups.firstIndex(where: { $0.section == section }) else { return }
            if let before, let index = groups[g].ids.firstIndex(of: before) {
                groups[g].ids.insert(id, at: index)
            } else {
                groups[g].ids.append(id)
            }
        }
        for step in steps {
            switch step {
            case .move(let id, let section, let before):
                for g in groups.indices { groups[g].ids.removeAll { $0 == id } }
                place(id, in: section, before: before)
            case .insert(let id, let section, let before):
                place(id, in: section, before: before)
            }
        }
        let dropped = Set(removedSections)
        return groups.filter { !dropped.contains($0.section) }
    }
}
