public import Foundation

/// Finds the classic session file a migration reads, without reading it.
///
/// Classic saves `~/Library/Application Support/cmux/session-<bundle>.json`
/// per channel, a `-previous` copy, and archives in `session-history/`. The
/// finder prefers the classic channel that matches this build's own bundle id
/// (cmux-next stable migrates classic stable; nightly migrates nightly), then
/// the channel saved last. Classic debug builds are never a source.
///
/// ```swift
/// let finder = ClassicMigrationSourceFinder(support: temporaryDirectory, ownBundleID: "com.cmuxterm.app")
/// let files = finder.candidates()   // primary, -previous, newest archive
/// ```
public nonisolated struct ClassicMigrationSourceFinder: Sendable {
    /// Classic's shipping channels, stable first.
    public static let channels = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc", "com.cmuxterm.app.staging"]

    /// The Application Support folder (classic's files are in its `cmux` folder).
    public let support: URL
    /// This build's bundle id; nil prefers no channel.
    public let ownBundleID: String?

    public init(support: URL, ownBundleID: String?) {
        self.support = support
        self.ownBundleID = ownBundleID
    }

    /// The classic channel this build replaces: its bundle id without a
    /// cmux-next suffix (`com.cmuxterm.app.nightly.cmux-next` → nightly).
    public var ownChannel: String? {
        guard let ownBundleID else { return nil }
        return Self.channels.reversed().first { ownBundleID == $0 || ownBundleID.hasPrefix($0 + ".") }
    }

    /// The channel to read: this build's own when classic saved one, else
    /// the channel whose session file changed last.
    public func channel() -> String? {
        // A channel whose session file is gone still counts by its `-previous` copy.
        let saved = Self.channels.compactMap { channel -> (String, Date)? in
            (modified(primary(channel)) ?? modified(previous(channel))).map { (channel, $0) }
        }
        if let own = ownChannel, saved.contains(where: { $0.0 == own }) { return own }
        return saved.max { $0.1 < $1.1 }?.0
    }

    /// The files to try, best first, for `channel` (``channel()`` when nil):
    /// the session file, its `-previous` copy, then the newest archive.
    public func candidates(channel: String? = nil) -> [(url: URL, bundleID: String)] {
        guard let channel = channel ?? self.channel() else { return [] }
        var files = [primary(channel), previous(channel)]
        let history = folder.appendingPathComponent("session-history", isDirectory: true)
        let prefix = "session-\(channel)-"
        let archived = ((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
            .filter { name in
                // `session-<bundle>-<millis>-w..-p...json`; a longer bundle id (nightly vs stable) is another channel.
                guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
                return name.dropFirst(prefix.count).first?.isNumber == true
            }
            .sorted { Self.millis($0, prefix) > Self.millis($1, prefix) }
        if let newest = archived.first { files.append(history.appendingPathComponent(newest)) }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, channel) }
    }

    /// What identifies `url`'s current save; nil when it cannot be read.
    public func source(_ url: URL, bundleID: String, createdAt: Double?) -> ClassicMigrationSource? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ClassicMigrationSource(path: url.path, bundleID: bundleID, size: size, modifiedAt: modified, createdAt: createdAt)
    }

    private var folder: URL { support.appendingPathComponent("cmux", isDirectory: true) }

    private func primary(_ channel: String) -> URL { folder.appendingPathComponent("session-\(channel).json") }

    private func previous(_ channel: String) -> URL { folder.appendingPathComponent("session-\(channel)-previous.json") }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func millis(_ name: String, _ prefix: String) -> Int {
        Int(name.dropFirst(prefix.count).prefix { $0.isNumber }) ?? 0
    }
}
