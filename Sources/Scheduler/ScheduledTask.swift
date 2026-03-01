import Foundation

// MARK: - ScheduledTask

struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var cronExpression: String
    var command: String
    var workingDirectory: String?
    var environment: [String: String]?
    var isEnabled: Bool
    var allowOverlap: Bool
    var useWorktree: Bool?
    var onSuccess: String?
    var onFailure: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        cronExpression: String,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        isEnabled: Bool = true,
        allowOverlap: Bool = false,
        useWorktree: Bool? = nil,
        onSuccess: String? = nil,
        onFailure: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cronExpression = cronExpression
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.isEnabled = isEnabled
        self.allowOverlap = allowOverlap
        self.useWorktree = useWorktree
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.createdAt = createdAt
    }
}

// MARK: - TaskRunStatus

enum TaskRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

// MARK: - CronExpression

struct CronExpression: Equatable, Sendable {
    let minutes: Set<Int>       // 0-59
    let hours: Set<Int>         // 0-23
    let daysOfMonth: Set<Int>   // 1-31
    let months: Set<Int>        // 1-12
    let daysOfWeek: Set<Int>    // Calendar convention: 1=Sun, 2=Mon, ..., 7=Sat

    private let dayOfMonthRestricted: Bool
    private let dayOfWeekRestricted: Bool

    /// Parse a standard 5-field cron expression: minute hour day-of-month month day-of-week.
    /// Supports: * (wildcard), N (value), N-M (range), N,M (list), */N (step), N-M/S (range+step).
    init?(_ expression: String) {
        let fields = expression.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        guard fields.count == 5 else { return nil }

        guard let mins = CronExpression.parseField(fields[0], range: 0...59),
              let hrs = CronExpression.parseField(fields[1], range: 0...23),
              let doms = CronExpression.parseField(fields[2], range: 1...31),
              let mos = CronExpression.parseField(fields[3], range: 1...12),
              let dows = CronExpression.parseField(fields[4], range: 0...7)
        else { return nil }

        guard !mins.isEmpty, !hrs.isEmpty, !doms.isEmpty, !mos.isEmpty, !dows.isEmpty
        else { return nil }

        self.minutes = mins
        self.hours = hrs
        self.daysOfMonth = doms
        self.months = mos
        // Convert cron day-of-week (0=Sun, 1=Mon, ..., 6=Sat, 7=Sun) to Calendar (1=Sun, ..., 7=Sat)
        self.daysOfWeek = Set(dows.map { ($0 % 7) + 1 })

        self.dayOfMonthRestricted = (fields[2] != "*")
        self.dayOfWeekRestricted = (fields[4] != "*")
    }

    /// Find the next fire date after the given date. DST-safe via Calendar date construction.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        // Start from the next minute boundary after `date`
        guard let startMinute = calendar.date(byAdding: .minute, value: 1, to: date) else {
            return nil
        }
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startMinute)

        var year = comps.year!
        var month = comps.month!
        var day = comps.day!
        var hour = comps.hour!
        var minute = comps.minute!

        let sortedMinutes = minutes.sorted()
        let sortedHours = hours.sorted()
        let sortedMonths = months.sorted()

        // Safety: search up to 5 years ahead
        let maxYear = year + 5

        while year <= maxYear {
            // 1. Check/advance month
            if !months.contains(month) {
                if let next = sortedMonths.first(where: { $0 > month }) {
                    month = next
                } else {
                    year += 1
                    month = sortedMonths[0]
                }
                day = 1
                hour = sortedHours[0]
                minute = sortedMinutes[0]
                continue
            }

            // 2. Validate day is within calendar month range
            guard let monthDate = CronExpression.makeDate(year: year, month: month, day: 1, calendar: calendar),
                  let daysInMonth = calendar.range(of: .day, in: .month, for: monthDate)?.count
            else {
                month += 1
                if month > 12 { month = 1; year += 1 }
                day = 1; hour = sortedHours[0]; minute = sortedMinutes[0]
                continue
            }

            if day > daysInMonth {
                month += 1
                if month > 12 { month = 1; year += 1 }
                day = 1; hour = sortedHours[0]; minute = sortedMinutes[0]
                continue
            }

            // 3. Check day-of-month and/or day-of-week
            let domMatch = daysOfMonth.contains(day)
            let dowMatch: Bool
            if let dayDate = CronExpression.makeDate(year: year, month: month, day: day, calendar: calendar) {
                dowMatch = daysOfWeek.contains(calendar.component(.weekday, from: dayDate))
            } else {
                dowMatch = false
            }

            let dayMatches: Bool
            if dayOfMonthRestricted && dayOfWeekRestricted {
                dayMatches = domMatch || dowMatch  // POSIX: OR when both specified
            } else if dayOfMonthRestricted {
                dayMatches = domMatch
            } else if dayOfWeekRestricted {
                dayMatches = dowMatch
            } else {
                dayMatches = true
            }

            if !dayMatches {
                day += 1
                hour = sortedHours[0]; minute = sortedMinutes[0]
                continue
            }

            // 4. Check/advance hour
            if !hours.contains(hour) {
                if let next = sortedHours.first(where: { $0 > hour }) {
                    hour = next
                    minute = sortedMinutes[0]
                    continue
                } else {
                    day += 1
                    hour = sortedHours[0]; minute = sortedMinutes[0]
                    continue
                }
            }

            // 5. Check/advance minute
            if !minutes.contains(minute) {
                if let next = sortedMinutes.first(where: { $0 > minute }) {
                    minute = next
                } else {
                    hour += 1
                    if hour > 23 {
                        day += 1
                        hour = sortedHours[0]
                    }
                    minute = sortedMinutes[0]
                    continue
                }
            }

            // All fields match — construct the result
            var resultComps = DateComponents()
            resultComps.year = year
            resultComps.month = month
            resultComps.day = day
            resultComps.hour = hour
            resultComps.minute = minute
            resultComps.second = 0

            if let result = calendar.date(from: resultComps) {
                return result
            }

            // Date construction failed (e.g., invalid calendar date) — advance
            day += 1
            hour = sortedHours[0]; minute = sortedMinutes[0]
        }

        return nil
    }

    // MARK: - Field Parsing

    private static func parseField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        if field.contains(",") {
            var result = Set<Int>()
            for part in field.split(separator: ",") {
                guard let values = parseSingleField(String(part), range: range) else { return nil }
                result.formUnion(values)
            }
            return result
        }
        return parseSingleField(field, range: range)
    }

    private static func parseSingleField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        // Step: */N or N-M/S or N/S
        if field.contains("/") {
            let parts = field.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let step = Int(parts[1]), step > 0 else { return nil }

            let baseRange: ClosedRange<Int>
            if parts[0] == "*" {
                baseRange = range
            } else if parts[0].contains("-") {
                guard let r = parseRange(String(parts[0]), range: range) else { return nil }
                baseRange = r
            } else {
                guard let start = Int(parts[0]), range.contains(start) else { return nil }
                baseRange = start...range.upperBound
            }

            var result = Set<Int>()
            var value = baseRange.lowerBound
            while value <= baseRange.upperBound {
                result.insert(value)
                value += step
            }
            return result
        }

        // Wildcard
        if field == "*" {
            return Set(range)
        }

        // Range: N-M
        if field.contains("-") {
            guard let r = parseRange(field, range: range) else { return nil }
            return Set(r)
        }

        // Single value
        guard let value = Int(field), range.contains(value) else { return nil }
        return Set([value])
    }

    private static func parseRange(_ field: String, range: ClosedRange<Int>) -> ClosedRange<Int>? {
        let parts = field.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              range.contains(lower),
              range.contains(upper),
              lower <= upper
        else { return nil }
        return lower...upper
    }

    private static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)
    }
}

// MARK: - ScheduledTask + Cron

extension ScheduledTask {
    var parsedCron: CronExpression? {
        CronExpression(cronExpression)
    }

    func nextFireDate(after date: Date) -> Date? {
        parsedCron?.nextFireDate(after: date)
    }
}

// MARK: - TaskRun

struct TaskRun: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let taskId: UUID
    var panelId: UUID?
    let startedAt: Date
    var completedAt: Date?
    var exitCode: Int32?
    var status: TaskRunStatus

    init(
        id: UUID = UUID(),
        taskId: UUID,
        panelId: UUID? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        status: TaskRunStatus = .running
    ) {
        self.id = id
        self.taskId = taskId
        self.panelId = panelId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitCode = exitCode
        self.status = status
    }
}
