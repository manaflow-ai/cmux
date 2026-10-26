import CmuxNextCompat
public import Foundation

/// When this app last opened a Chromium tab: one small JSON file in the
/// Chromium storage root (`<Application Support>/<bundle id>/Chromium`),
/// written atomically. `ChromiumWarmup` starts Chromium at launch only for a
/// user who opened a Chromium tab recently; a user who never browses never
/// pays for it. Read and written off the main thread.
nonisolated public struct ChromiumUseRecord: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The record beside the profiles in `storageRoot`.
    public init(storageRoot: URL) {
        self.init(url: storageRoot.appending(path: "cmux-last-tab-opened.json", directoryHint: .notDirectory))
    }

    private struct Payload: Codable {
        var lastTabOpened: Date
    }

    /// The last Chromium tab open, nil when none was recorded (or the file
    /// does not parse).
    public func lastTabOpened() -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.blockingDecode(Payload.self, from: data))?.lastTabOpened
    }

    /// Records a Chromium tab open at `date`; false when it could not.
    @discardableResult
    public func recordTabOpened(at date: Date) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(lastTabOpened: date)) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// True when a Chromium tab opened within `window` before `now`.
    public func usedRecently(within window: TimeInterval, now: Date = Date()) -> Bool {
        guard let last = lastTabOpened() else { return false }
        let age = now.timeIntervalSince(last)
        // A date after now (a clock set back) is not a recent use.
        return age >= 0 && age <= window
    }
}
