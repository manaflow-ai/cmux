public import Foundation
import ImageIO

/// How a dynamic macOS wallpaper changes (`appearance.backgroundDynamic`).
public nonisolated enum BackdropDynamicMode: String, CaseIterable, Sendable {
    /// Its light or dark frame, with the window's appearance.
    case appearance
    /// Its frames through the day, like macOS's Dynamic desktop: by the sun, or by the clock.
    case time
}

/// The frame schedule of a dynamic HEIC, read from its `apple_desktop` metadata once per file and
/// cached: sun positions (`solar`), fractions of the day (`h24`), and its light and dark frames
/// (`apr`, and the `ap` pair the other two carry).
public nonisolated struct BackdropDynamicFrames: Equatable, Sendable {
    /// A frame shown while the sun is nearest this position.
    public struct SolarFrame: Equatable, Sendable {
        public let position: SunPosition
        public let index: Int
    }

    /// A frame shown from this fraction of the local day (0 midnight, 0.5 noon).
    public struct ClockFrame: Equatable, Sendable {
        public let time: Double
        public let index: Int
    }

    public let solar: [SolarFrame]
    public let clock: [ClockFrame]
    /// The frames for light and dark (0 when the file names none).
    public let light: Int
    public let dark: Int

    /// The frame of `date`: the sun's nearest position for a solar picture, the latest clock
    /// frame for an h24 one, else the light frame while the sun is above ``SunPosition/darkAltitude``.
    public func frame(at date: Date, location: BackdropLocation, calendar: Calendar) -> Int {
        if !solar.isEmpty {
            let sun = location.sunPosition(at: date)
            return solar.min { $0.position.angle(to: sun) < $1.position.angle(to: sun) }?.index ?? light
        }
        if !clock.isEmpty {
            let wall = calendar.dateComponents([.hour, .minute, .second], from: date)
            let fraction = Double((wall.hour ?? 0) * 3_600 + (wall.minute ?? 0) * 60 + (wall.second ?? 0)) / 86_400
            let sorted = clock.sorted { $0.time < $1.time }
            // Before the first frame of the day: the last one, from the evening before.
            return (sorted.last { $0.time <= fraction } ?? sorted.last)?.index ?? light
        }
        return location.sunPosition(at: date).isDark ? dark : light
    }

    /// The frames of the picture at `url` (its metadata only, no decode); nil for a file without
    /// dynamic metadata (or that is not there). `BackdropSwitchClock` keeps them per path.
    public static func read(contentsOf url: URL) -> BackdropDynamicFrames? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(read)
    }

    /// The frames `source`'s first image's metadata names; nil when it names none.
    static func read(_ source: CGImageSource) -> BackdropDynamicFrames? {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        func valid(_ value: Any?) -> Int? { (value as? Int).flatMap { $0 >= 0 && $0 < count ? $0 : nil } }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        for name in ["apple_desktop:solar", "apple_desktop:h24", "apple_desktop:apr"] {
            guard let plist = BackdropAppearance.plist(name, in: metadata) else { continue }
            let pair = (plist["ap"] as? [String: Any]) ?? plist
            let solar = (plist["si"] as? [[String: Any]] ?? []).compactMap { entry -> SolarFrame? in
                guard let altitude = number(entry["a"]), let azimuth = number(entry["z"]), let index = valid(entry["i"]) else { return nil }
                return SolarFrame(position: SunPosition(altitude: altitude, azimuth: azimuth), index: index)
            }
            let clock = (plist["ti"] as? [[String: Any]] ?? []).compactMap { entry -> ClockFrame? in
                guard let time = number(entry["t"]), let index = valid(entry["i"]) else { return nil }
                return ClockFrame(time: time, index: index)
            }
            let highest = solar.max { $0.position.altitude < $1.position.altitude }?.index
            let lowest = solar.min { $0.position.altitude < $1.position.altitude }?.index
            let light = valid(pair["l"]) ?? highest ?? 0, dark = valid(pair["d"]) ?? lowest ?? light
            return BackdropDynamicFrames(solar: solar, clock: clock, light: light, dark: dark)
        }
        return nil
    }

    /// When the frame shown after `date` next changes, to the second; nil when it holds for the
    /// next two days (or `frame` never changes).
    public func nextChange(after date: Date, location: BackdropLocation, calendar: Calendar) -> Date? {
        Self.nextChange(after: date) { frame(at: $0, location: location, calendar: calendar) }
    }

    /// The first instant after `date` where `value` differs from its value at `date`: stepped in
    /// 5 minutes for two days, then narrowed to the second.
    public static func nextChange<Value: Equatable>(after date: Date, _ value: (Date) -> Value) -> Date? {
        let now = value(date)
        var low = date
        for step in 1...576 {
            let high = date.addingTimeInterval(Double(step) * 300)
            guard value(high) == now else {
                var high = high
                while high.timeIntervalSince(low) > 1 {
                    let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if value(middle) == now { low = middle } else { high = middle }
                }
                return high
            }
            low = high
        }
        return nil
    }
}
