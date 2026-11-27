import Foundation

/// The time mock data is stamped with: the seeded Chief transcript, a sent
/// message, its read receipt and the reply. Real time, unless a DEBUG launch
/// passes `-cmux-mobile-fixed-now <unix seconds>`: then every mock stamp is
/// that one instant, so a screenshot shows the same times on every run (the
/// App Review gate's stills, which a run compares with its base's).
public enum MockClock {
    /// The fixed instant from the launch arguments, if any.
    public static let fixed: Date? = fixedNow(arguments: ProcessInfo.processInfo.arguments)

    public static func now() -> Date { fixed ?? Date() }

    /// `-cmux-mobile-fixed-now <unix seconds>` (DEBUG builds only).
    static func fixedNow(arguments: [String]) -> Date? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-cmux-mobile-fixed-now"), index + 1 < arguments.count,
              let seconds = TimeInterval(arguments[index + 1]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
        #else
        return nil
        #endif
    }
}
