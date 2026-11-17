public import Foundation
public import CmuxNextDesign

/// A background that changes on its own, like macOS's automatic wallpaper: a shuffle turning every
/// period (`daily`, `folder:`), the time-of-day schedule (`schedule`), or a dynamic macOS wallpaper
/// following the sun (`system:` with `appearance.backgroundDynamic: "time"`). Light and Dark
/// (`appearance`) is no switch: each view resolves it for its own appearance, with no timer.
/// ``turn(at:calendar:)`` is pure (it reads files, never the main actor), so a caller may run it
/// anywhere; the app arms one timer to its `next`.
public struct BackdropSwitch: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case shuffle(BackdropShuffle)
        case schedule(BackdropTimeOfDay)
        /// A macOS wallpaper at this absolute path, shown at its frame of now.
        case dynamic(String)
    }

    public let source: Source
    /// Dynamic macOS wallpapers in it follow the sun or clock (`appearance.backgroundDynamic: "time"`).
    public let followsTime: Bool
    /// `appearance.backgroundLocation`; nil reads the time zone's city at each turn, so a time
    /// zone change moves the sun too.
    public let location: BackdropLocation?

    public init(source: Source, followsTime: Bool = false, location: BackdropLocation? = nil) {
        self.source = source
        self.followsTime = followsTime
        self.location = location
    }

    /// The switch `root`'s background is; nil for a fixed background, Light and Dark, or none.
    public init?(_ root: JSONValue) {
        guard let raw = root.value(at: BackdropSelectionSetting.configPath)?.stringValue else { return nil }
        let followsTime = BackdropSelectionSetting.dynamicMode(root) == .time
        let location = root.value(at: BackdropSelectionSetting.locationPath)?.stringValue.flatMap(BackdropLocation.init(text:))
        if let shuffle = BackdropSelectionSetting.shuffle(root) {
            self.init(source: .shuffle(shuffle))
        } else if raw == BackdropSelectionSetting.scheduleID {
            guard let schedule = BackdropSelectionSetting.schedule(root) else { return nil }
            self.init(source: .schedule(schedule), followsTime: followsTime, location: location)
        } else if followsTime, case .system(let path)? = BackdropSelection(id: raw), !AppleWallpapers.isVideo(path) {
            self.init(source: .dynamic(path), followsTime: true, location: location)
        } else {
            return nil
        }
    }

    /// Reads a dynamic wallpaper's frames (``BackdropSwitchClock`` keeps them per path).
    public typealias FramesReader = (URL) -> BackdropDynamicFrames?

    /// The picture shown at `date` and when it next changes (nil: it holds; no timer needed).
    public func turn(at date: Date, calendar: Calendar,
                     frames: FramesReader = BackdropDynamicFrames.read(contentsOf:)) -> (picture: BackdropSelection?, next: Date?) {
        let location = location ?? BackdropLocation.of(calendar.timeZone)
        switch source {
        case .shuffle(let shuffle):
            return (shuffle.pick(on: date, calendar: calendar), shuffle.rotation.nextTurn(after: date, calendar: calendar))
        case .schedule(let schedule):
            let (value, next) = schedule.resolve(at: date, location: location, calendar: calendar)
            let (picture, frameNext) = pin(value.flatMap(BackdropSelection.init(id:)), at: date, location: location,
                                           calendar: calendar, frames: frames)
            return (picture, [next, frameNext].compactMap { $0 }.min())
        case .dynamic(let path):
            return pin(.system(path: path), at: date, location: location, calendar: calendar, frames: frames)
        }
    }

    /// A dynamic macOS wallpaper as its moment of `date` when this switch follows time, and when
    /// that moment ends; anything else as is, holding.
    func pin(_ picture: BackdropSelection?, at date: Date, location: BackdropLocation,
             calendar: Calendar, frames read: FramesReader) -> (BackdropSelection?, Date?) {
        guard followsTime, case .system(let path)? = picture, !AppleWallpapers.isVideo(path) else { return (picture, nil) }
        let full: URL?
        if path.lowercased().hasSuffix(".madesktop") {
            guard let wallpaper = AppleWallpaper(path: path, assets: .recent()), wallpaper.isDynamic else { return (picture, nil) }
            full = wallpaper.fullResolution
        } else {
            full = URL(fileURLWithPath: path)
        }
        let isDark = { (moment: Date) in location.sunPosition(at: moment).isDark }
        guard let full, let frames = read(full) else {
            // Not downloaded yet (or one picture): its light or dark thumbnail by the sun.
            guard full == nil else { return (picture, nil) }
            return (.moment(path: path, frame: -1, dark: isDark(date)), BackdropDynamicFrames.nextChange(after: date, isDark))
        }
        let frame = frames.frame(at: date, location: location, calendar: calendar)
        return (.moment(path: path, frame: frame, dark: frame == frames.dark && frames.dark != frames.light),
                frames.nextChange(after: date, location: location, calendar: calendar))
    }
}
