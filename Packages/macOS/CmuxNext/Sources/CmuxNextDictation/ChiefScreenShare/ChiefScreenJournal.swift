import CmuxNextCompat
public import Foundation

/// The files a sharing session leaves for the Chief, under one directory (the Chief home's
/// `optchat/screen`, mode 0700):
///
/// - `latest.jpg`, `latest.json`: the current screen while sharing ("look now"); deleted when it stops.
/// - `frames/<yyyy-MM-dd>/<HHmmss-SSS>.jpg`: the source frame of each remembered entry; the newest
///   `keepFrames` stay, older ones are deleted.
/// - `inbox/<epoch ms>.json`: one ``ChiefScreenObservation`` per remembered frame. The Chief's brain
///   (optchat-chief `screen_share.rs`) turns them into a memory note and deletes them.
///
/// Every file is written whole (a temporary file, then a rename), so the brain never reads half of one.
///
/// ```swift
/// let journal = ChiefScreenJournal(directory: home.appending(path: "optchat/screen"))
/// await journal.beginSharing()
/// let seen = await journal.record(frame, at: .now, remember: true)
/// ```
public actor ChiefScreenJournal: ChiefScreenJournaling {
    private let directory: URL
    private let keepFrames: Int
    private let files = FileManager.checked
    private let dayFormat: DateFormatter
    private let timeFormat: DateFormatter
    private let fileFormat: DateFormatter
    private var sharing = false

    /// - Parameters:
    ///   - directory: Where the files go.
    ///   - keepFrames: How many remembered frames stay on disk.
    ///   - timeZone: The zone of the local day and time; tests pass a fixed one.
    public init(directory: URL, keepFrames: Int = 1000, timeZone: TimeZone = .current) {
        self.directory = directory
        self.keepFrames = keepFrames
        func format(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter
        }
        dayFormat = format("yyyy-MM-dd")
        timeFormat = format("HH:mm:ss")
        fileFormat = format("HHmmss-SSS")
    }

    /// The current screen's JPEG while sharing.
    public nonisolated var latestFrame: URL { directory.appending(path: "latest.jpg") }
    /// The current screen's observation while sharing.
    public nonisolated var latestEntry: URL { directory.appending(path: "latest.json") }
    /// The entries the brain has not taken yet.
    public nonisolated var inbox: URL { directory.appending(path: "inbox", directoryHint: .isDirectory) }
    /// The remembered frames, one folder per day.
    public nonisolated var frames: URL { directory.appending(path: "frames", directoryHint: .isDirectory) }

    public func beginSharing() {
        sharing = true
    }

    public func endSharing() {
        sharing = false
        try? files.removeItem(at: latestFrame)
        try? files.removeItem(at: latestEntry)
    }

    public func record(_ frame: ChiefScreenFrame, at: Date, remember: Bool) -> ChiefScreenObservation? {
        guard sharing else { return nil }
        let day = dayFormat.string(from: at)
        let source = remember
            ? frames.appending(path: day, directoryHint: .isDirectory).appending(path: "\(fileFormat.string(from: at)).jpg")
            : latestFrame
        let observation = ChiefScreenObservation(at: at, day: day, time: timeFormat.string(from: at), app: frame.app,
                                                 window: frame.window, text: frame.text, frame: source.path)
        do {
            try makeDirectory(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try frame.jpeg.blockingWrite(to: latestFrame, options: .atomic)
            try encoder.encode(observation).blockingWrite(to: latestEntry, options: .atomic)
            guard remember else { return observation }
            try makeDirectory(source.deletingLastPathComponent())
            try frame.jpeg.blockingWrite(to: source, options: .atomic)
            try makeDirectory(inbox)
            let name = "\(Int64((at.timeIntervalSince1970 * 1000).rounded())).json"
            try encoder.encode(observation).blockingWrite(to: inbox.appending(path: name), options: .atomic)
            prune()
            return observation
        } catch {
            return nil
        }
    }

    private func makeDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Deletes the oldest remembered frames past `keepFrames` (names sort by day, then time), and
    /// the oldest inbox entries past `keepFrames` when no Chief host takes them.
    private func prune() {
        let entries = ((try? files.contentsOfDirectory(atPath: inbox.path)) ?? []).filter { $0.hasSuffix(".json") }
            .sorted { (Int64($0.dropLast(5)) ?? 0) < (Int64($1.dropLast(5)) ?? 0) }
        for old in entries.dropLast(keepFrames) { try? files.removeItem(at: inbox.appending(path: old)) }
        let days = ((try? files.contentsOfDirectory(atPath: frames.path)) ?? []).sorted()
        var all: [URL] = []
        for day in days {
            let folder = frames.appending(path: day, directoryHint: .isDirectory)
            let names = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
            all += names.map { folder.appending(path: $0) }
        }
        for old in all.dropLast(keepFrames) { try? files.removeItem(at: old) }
    }
}
