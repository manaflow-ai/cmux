import Foundation

/// When relative row times (`sidebar.relativeTimestamps`: `5m`, `2h`) next read differently, so a quiet list
/// still ages its labels. Rows count from the current minute (`SidebarLayoutOptions.now`), so a label changes
/// only as a minute turns: a row under an hour old at the next minute, one under a day old as it reaches its
/// next whole hour. A row a day old or more reads in days, as before, and needs no tick.
nonisolated enum SidebarRelativeTimesTick {
    /// The wait until the first label of `changes` (each row's last activity) reads differently, a second
    /// past that minute; nil when no row is under a day old.
    static func delay(_ changes: some Sequence<Date>, now: Date) -> Duration? {
        let minute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        var steps: Int?
        for change in changes {
            let age = minute - change.timeIntervalSince1970
            guard age < 86_400 else { continue }
            // Whole minutes until the label turns.
            let turn = age < 3_600 ? 1 : Int(((3_600 - age.truncatingRemainder(dividingBy: 3_600)) / 60).rounded(.up))
            steps = min(steps ?? max(1, turn), max(1, turn))
        }
        guard let steps else { return nil }
        let fire = minute + TimeInterval(steps) * 60 + 1
        return .milliseconds(Int(((fire - now.timeIntervalSince1970) * 1_000).rounded()))
    }
}
