import CmuxNextCompat
public import Foundation
import os

/// The desktop choice in macOS's wallpaper store index
/// (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, ``AppleWallpapers/storeIndex``)
/// for one display: what `NSWorkspace.desktopImageURL(for:)` cannot say on its own. It names the
/// aerial a moving desktop plays (`Provider` `com.apple.wallpaper.choice.aerials`, its asset id in
/// the `Configuration`), the files of a picture choice (a rotation's current one when macOS writes
/// it), and how a dynamic picture moves (time of day, the appearance, or pinned light or dark).
///
/// The index is undocumented: every read is lenient, and a choice it can't read is nil, so the
/// desktop then shows what `NSWorkspace` reports. A display's own entry (`Displays`, by display
/// UUID) wins over the one for every display (`AllSpacesAndDisplays`). A Space's own entry
/// (`Spaces`) is not read: which Space is active is not public, and `NSWorkspace` already reports
/// the active Space's picture.
///
/// ```swift
/// let choice = DesktopStoreChoice.read(indexData, display: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
/// choice?.aerialIDs   // ["B2FC91ED-..."] for an aerial desktop
/// ```
nonisolated struct DesktopStoreChoice: Equatable, Sendable {
    /// How a dynamic picture moves, as the choice names it.
    nonisolated enum Motion: Equatable, Sendable {
        /// Through the day (System Settings' Dynamic): the frame of the time.
        case time
        /// With the light or dark appearance (Automatic).
        case appearance
        /// Pinned to its light frame.
        case light
        /// Pinned to its dark frame.
        case dark
    }

    /// The choice's provider (`com.apple.wallpaper.choice.image`, `…aerials`, `…dynamic`); nil when it names none.
    let provider: String?
    /// Every string in the choice, nested property lists decoded, in order.
    let strings: [String]

    /// Whether the desktop is an aerial (a moving wallpaper idleassetsd downloads).
    var isAerial: Bool { provider?.lowercased().contains("aerial") == true }

    /// The asset ids the choice names, when it is an aerial: one names the movie idleassetsd writes.
    var aerialIDs: [String] {
        guard isAerial else { return [] }
        return strings.filter { AppleWallpapers.isSafeAerialID($0) && $0.contains("-") }
    }

    /// The files the choice names (`file://` URLs and absolute paths), in order.
    var files: [URL] {
        strings.compactMap { text in
            if text.hasPrefix("file://") { return URL(string: text).map(\.standardizedFileURL) }
            return text.hasPrefix("/") ? URL(fileURLWithPath: text).standardizedFileURL : nil
        }
    }

    /// How the choice moves a dynamic picture; nil when it names no way (the file's own metadata decides).
    var motion: Motion? {
        for text in strings {
            switch text.lowercased() {
            case "dynamic", "timeofday", "time-of-day", "solar": return .time
            case "automatic", "auto", "appearance": return .appearance
            case "light": return .light
            case "dark": return .dark
            default: continue
            }
        }
        return nil
    }

    /// The desktop choice for `display` in an index's bytes; nil when the index has none.
    /// - Parameters:
    ///   - data: `Index.plist`'s contents.
    ///   - display: The display's UUID string (`CGDisplayCreateUUIDFromDisplayID`); nil reads only
    ///     the entry for every display.
    static func read(_ data: Data, display: String?) -> DesktopStoreChoice? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var scopes: [[String: Any]] = []
        if let display, let displays = root["Displays"] as? [String: Any] {
            let key = displays.keys.first { $0.caseInsensitiveCompare(display) == .orderedSame }
            if let key, let own = displays[key] as? [String: Any] { scopes.append(own) }
        }
        if let all = root["AllSpacesAndDisplays"] as? [String: Any] { scopes.append(all) }
        for scope in scopes {
            guard let desktop = scope["Desktop"] as? [String: Any] else { continue }
            let content = desktop["Content"] as? [String: Any] ?? desktop
            let choice = (content["Choices"] as? [Any])?.first as? [String: Any]
            var found: [String] = []
            AppleWallpapers.collectStrings(choice ?? content, into: &found, depth: 0)
            guard choice != nil || !found.isEmpty else { continue }
            return DesktopStoreChoice(provider: choice?["Provider"] as? String, strings: found)
        }
        return nil
    }

    /// The files the store names inside a rotating folder, in order: the first that decodes is
    /// the one macOS shows now. Only the folder and the named files are resolved; the folder is
    /// not listed (a folder report with none named falls back to the first picture by name).
    /// - Parameters:
    ///   - folder: The folder macOS reports.
    ///   - named: The files the store's choice names (``files``).
    static func shownFiles(in folder: URL, named: [URL]) -> [URL] {
        guard !named.isEmpty else { return [] }
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return named.filter { file in
            (file.standardizedFileURL.resolvingSymlinksInPath().path as NSString).deletingLastPathComponent == folderPath
        }
    }

    /// The frame of a dynamic picture the desktop shows at `date`, and when it next changes.
    /// - Parameters:
    ///   - frames: The picture's dynamic metadata; nil for a still (no frame: the appearance decides).
    ///   - motion: How the store says it moves; nil follows the file (time of day when it has
    ///     solar or clock frames, else the appearance).
    ///   - date: Now.
    ///   - location: Where the sun is computed (``BackdropLocation/of(_:)`` of the time zone).
    ///   - calendar: The wall clock of a clock (h24) picture.
    /// - Returns: The frame (nil: the decode's light or dark frame) and the next change (nil: none soon).
    static func frame(of frames: BackdropDynamicFrames?, motion: Motion?, at date: Date,
                      location: BackdropLocation, calendar: Calendar) -> (index: Int?, next: Date?) {
        guard let frames else { return (nil, nil) }
        switch motion ?? (frames.solar.isEmpty && frames.clock.isEmpty ? .appearance : .time) {
        case .appearance: return (nil, nil)
        case .light: return (frames.light, nil)
        case .dark: return (frames.dark, nil)
        case .time:
            return (frames.frame(at: date, location: location, calendar: calendar),
                    frames.nextChange(after: date, location: location, calendar: calendar))
        }
    }
}

/// The store index and each picture's dynamic metadata, read once per file version and shared by
/// every reading (the 5-second re-read stats them and parses nothing new). The live desktop watch
/// owns one and uses it only on its queue; the lock keeps it safe from anywhere.
nonisolated final class DesktopStoreCache: Sendable {

    private nonisolated struct State: Sendable {
        var index: (modified: Date?, data: Data?)?
        var choicesModified: Date?
        var choices: [String: DesktopStoreChoice?] = [:]
        var frames: [String: (modified: Date?, frames: BackdropDynamicFrames?)] = [:]
        var aerials: [String: (path: String?, retry: Date)] = [:]
        var moments: [String: (motion: DesktopStoreChoice.Motion?, index: Int?, next: Date?, until: Date)] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The index's bytes, read again only when its modification date moved.
    func indexData(at url: URL = AppleWallpapers.storeIndex) -> Data? {
        let modified = Self.modified(url)
        if let cached = state.withLock({ $0.index }), cached.modified == modified { return cached.data }
        let data = try? Data(blockingContentsOf: url)
        state.withLock { $0.index = (modified, data) }
        return data
    }

    /// The store's desktop choice for `display` (``DesktopStoreChoice/read(_:display:)``), parsed
    /// again only when the index's modification date moved.
    func choice(display: String?, index url: URL = AppleWallpapers.storeIndex) -> DesktopStoreChoice? {
        let modified = Self.modified(url), key = display?.uppercased() ?? ""
        if let known = state.withLock({ $0.choicesModified == modified ? $0.choices[key] : nil }) { return known }
        let choice = indexData(at: url).flatMap { DesktopStoreChoice.read($0, display: display) }
        state.withLock { state in
            if state.choicesModified != modified { state.choices = [:]; state.choicesModified = modified }
            state.choices[key] = .some(choice)
        }
        return choice
    }

    /// The dynamic metadata of the picture at `url`, read again only when the file changed.
    func frames(of url: URL) -> BackdropDynamicFrames? {
        let modified = Self.modified(url)
        if let cached = state.withLock({ $0.frames[url.path] }), cached.modified == modified { return cached.frames }
        let frames = url.pathExtension.lowercased() == "heic" ? BackdropDynamicFrames.read(contentsOf: url) : nil
        state.withLock { state in
            if state.frames.count >= 16 { state.frames.removeAll() }
            state.frames[url.path] = (modified, frames)
        }
        return frames
    }

    /// The frame of the picture at `path` at `date`, computed again only once its last next change
    /// passed (a still, or a picture that follows the appearance, holds for a minute).
    func moment(of path: String, motion: DesktopStoreChoice.Motion?, at date: Date,
                _ compute: () -> (index: Int?, next: Date?)) -> (index: Int?, next: Date?) {
        if let known = state.withLock({ $0.moments[path] }), known.motion == motion, date < known.until { return (known.index, known.next) }
        let moment = compute()
        state.withLock { state in
            if state.moments.count >= 16 { state.moments.removeAll() }
            state.moments[path] = (motion, moment.index, moment.next, moment.next ?? date.addingTimeInterval(60))
        }
        return moment
    }

    /// The downloaded aerial movie one of `ids` names. A hit is kept while the movie stays
    /// readable; a miss is looked up again at most once a minute (idleassetsd may still be
    /// downloading it), so the 5-second re-read does not list the aerial folders each time.
    func aerial(_ ids: [String], at date: Date = Date(), wallpapers: AppleWallpapers = .system) -> String? {
        let key = ids.joined(separator: "|")
        if let known = state.withLock({ $0.aerials[key] }) {
            if let path = known.path, FileManager.checked.isReadableFile(atPath: path) { return path }
            if known.path == nil, date < known.retry { return nil }
        }
        // Only the movies on disk: their names (entries.json) are not needed to match an id.
        let videos = wallpapers.videos(names: [:])
        var found: String?
        search: for id in ids {
            for case .system(let path) in videos where URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == id
                && FileManager.checked.isReadableFile(atPath: path) {
                found = path
                break search
            }
        }
        let entry = (path: found, retry: date.addingTimeInterval(60))
        state.withLock { state in
            if state.aerials.count >= 8 { state.aerials.removeAll() }
            state.aerials[key] = entry
        }
        return entry.path
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
