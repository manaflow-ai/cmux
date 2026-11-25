import AppKit
import CmuxNextWakeups

/// A host-ticking `Text`: `date` (Unix ms) shown in `dateStyle`, as SwiftUI's `Text(date, style:)`.
/// The renderer formats it and ticks it on ``AppSceneClock``, so the app sends nothing while it
/// counts (a seconds readout or a countdown costs no scene batch). The web twin is
/// webviews/src/apps/scene/sceneDate.ts; both read the person's locale and time zone, and a
/// `timeZone` prop (an IANA name) overrides the zone.
struct AppSceneDateText: Equatable {
    enum Style: String {
        /// The clock time, "9:41 AM" (the locale's hour cycle).
        case time
        /// The long date, "November 16, 2026".
        case date
        /// The time to or since the date as a timer, "4:05" or "1:02:03".
        case timer
        /// The time to or since the date in its two largest units, "2 hr, 23 min".
        case relative
        /// The signed difference in its largest unit, "+2 hours".
        case offset
    }

    var style: Style
    var date: Date
    var timeZone: TimeZone?

    /// The node's date text, or nil when it has no finite `date` (a plain Text).
    init?(_ node: AppSceneNode) {
        guard case .number(let ms)? = node.props["date"], ms.isFinite else { return nil }
        style = node.string("dateStyle").flatMap(Style.init(rawValue:)) ?? .time
        date = Date(timeIntervalSince1970: ms / 1000)
        timeZone = node.string("timeZone").flatMap(TimeZone.init(identifier:))
    }

    init(style: Style, date: Date, timeZone: TimeZone? = nil) {
        self.style = style
        self.date = date
        self.timeZone = timeZone
    }

    /// The text at `now`, in `locale`.
    func text(at now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        switch style {
        case .time:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone ?? .autoupdatingCurrent
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return formatter.string(from: date)
        case .date:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone ?? .autoupdatingCurrent
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            return formatter.string(from: date)
        case .timer:
            let total = Int(abs(date.timeIntervalSince(now)).rounded(.down))
            let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
            let tail = String(format: "%02d", seconds)
            return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(tail)" : "\(minutes):\(tail)"
        case .relative:
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .short
            formatter.maximumUnitCount = 2
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            return formatter.string(from: abs(date.timeIntervalSince(now)).rounded(.down)) ?? ""
        case .offset:
            let seconds = date.timeIntervalSince(now).rounded(.towardZero)
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            let magnitude = formatter.string(from: abs(seconds)) ?? ""
            return (seconds < 0 ? "-" : "+") + magnitude
        }
    }
}

/// The clock a mounted scene's ticking Texts read (``AppSceneNativeView`` owns one): a deadline at
/// each wall-clock second while any of them is in a window, none otherwise (``DemandTimer``; no
/// repeating timer).
@MainActor
final class AppSceneClock {
    private let timer = DemandTimer(owner: "apps.scene.date-text")
    private let views = NSHashTable<AppSceneTextNSView>.weakObjects()

    /// Starts ticking `view` (a ticking Text that moved into a window).
    func add(_ view: AppSceneTextNSView) {
        views.add(view)
        schedule()
    }

    /// Stops ticking `view` (it left its window or is no longer a ticking Text).
    func remove(_ view: AppSceneTextNSView) {
        views.remove(view)
        if views.count == 0 { timer.cancel() }
    }

    private func schedule() {
        guard views.count > 0 else { return }
        // To the next wall-clock second, so every ticking Text turns over with the system clock.
        let now = Date().timeIntervalSince1970
        let delay = max(0.001, now.rounded(.down) + 1 - now)
        timer.schedule(after: .milliseconds(Int((delay * 1000).rounded(.up)))) { @MainActor [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        for view in views.allObjects { view.tick(now) }
        schedule()
    }
}
