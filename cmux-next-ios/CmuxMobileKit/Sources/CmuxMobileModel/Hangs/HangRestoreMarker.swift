import Foundation

/// Written when the main thread has been stuck for the hard bound (8 s), before the system's
/// watchdog kills the app: when the hang began, how long it had lasted, and where the user was
/// (the app's own ``LastOpenLocation``, `LastOpenMemory`). The next launch reports the prior
/// hang once and puts the user back there through the same last-location restore every launch
/// already runs (`ShellModel.beginRestore`); there is no second state store.
public struct HangRestoreMarker: Codable, Equatable, Sendable {
    public var hangStarted: Date
    public var durationMilliseconds: Int
    public var location: LastOpenLocation?

    public init(hangStarted: Date, durationMilliseconds: Int, location: LastOpenLocation?) {
        self.hangStarted = hangStarted
        self.durationMilliseconds = durationMilliseconds
        self.location = location
    }

    public static var standardURL: URL { HangReports.standardDirectory.appendingPathComponent("restore-marker.json") }

    /// Writes it at once (the watchdog thread, while the main thread is stuck).
    public func write(to url: URL = HangRestoreMarker.standardURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            HangReports.logger.error("hang restore marker not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads and deletes the marker: a prior hang is reported once.
    public static func consume(at url: URL = HangRestoreMarker.standardURL) -> HangRestoreMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HangRestoreMarker.self, from: data)
    }

    /// Deletes the marker: the hard hang it stands for ended and the app lived on, so the next
    /// launch has no prior hang to report (watchdog thread).
    public static func clear(at url: URL = HangRestoreMarker.standardURL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            HangReports.logger.error("hang restore marker not cleared: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// At launch, after a hard hang: report it once (the `hangs` log), and make sure the
    /// launch restore has the screen the hang left. Returns the marker it consumed.
    @discardableResult
    public static func handlePriorHang(at url: URL = HangRestoreMarker.standardURL, lastOpen: LastOpenMemory = .standard) -> HangRestoreMarker? {
        guard let marker = consume(at: url) else { return nil }
        let place = marker.location.map { "\($0.rootTab) \($0.workspaceID ?? "-") \($0.tabID ?? "-")" } ?? "-"
        HangReports.logger.fault("prior launch hung: main thread stuck \(marker.durationMilliseconds) ms from \(marker.hangStarted.formatted(.iso8601), privacy: .public) at \(place, privacy: .public); restoring")
        if let location = marker.location, lastOpen.load() == nil { lastOpen.save(location) }
        return marker
    }
}
