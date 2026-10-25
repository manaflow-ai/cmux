import CmuxNextCompat
public import Foundation

/// The Downloads names that running downloads of both engines hold, so two
/// downloads that start together never pick the same name. A name is held
/// from `BrowserDownloadPolicy.place` until its download ends. The shared
/// reservations also record each temporary file (`BrowserDownloadTempFiles`)
/// so the next launch can delete what a crash left.
public final class BrowserDownloadReservations {
    public static let shared = BrowserDownloadReservations(tempFiles: .shared)
    private var paths: Set<String> = []
    /// Records each running download's temporary file (nil: no record).
    let tempFiles: BrowserDownloadTempFiles?

    public init(tempFiles: BrowserDownloadTempFiles? = nil) {
        self.tempFiles = tempFiles
    }

    func contains(_ url: URL) -> Bool { paths.contains(Self.key(url)) }
    func insert(_ url: URL) { paths.insert(Self.key(url)) }
    func remove(_ url: URL) { paths.remove(Self.key(url)) }
    /// The names held now (``key(_:)``), as a value for work off the main actor.
    var held: Set<String> { paths }

    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }
}

/// Where one download of either engine is written while it runs, a
/// temporary sibling of its file, and where it lands when it completes
/// (`finish`). A Downloads name lands with an exclusive rename: a file that
/// appeared there meanwhile, even a dangling symlink, is never written over,
/// and the download takes the next free name. A file the person confirmed
/// in a save panel is replaced only by a complete download, so a failed one
/// keeps the old file. Failure and cancel delete the temporary file
/// (`discard`). The temporary file is in the reservations' record
/// (`BrowserDownloadTempFiles`) from start to `discard`. The landing's
/// file calls run off the main actor (`finish`).
public final class BrowserDownloadPlacement {
    /// The engine writes here (Chromium adds `.crdownload` while it runs).
    public let temporaryURL: URL
    /// The file the download becomes; it can still move to the next free
    /// name when `finish` finds the name taken.
    public private(set) var finalURL: URL
    /// A save panel's file (replace it), or nil for a Downloads name.
    private let chosen: URL?
    /// The Downloads name the page suggested (after sanitizing), for the
    /// next free name.
    private let landingName: String
    private let reservations: BrowserDownloadReservations
    private var settled = false

    init(finalURL: URL, chosen: URL?, reservations: BrowserDownloadReservations) {
        self.finalURL = finalURL
        self.chosen = chosen
        landingName = finalURL.lastPathComponent
        self.reservations = reservations
        temporaryURL = Self.temporarySibling(of: finalURL)
        reservations.insert(finalURL)
        reservations.tempFiles?.add(temporaryURL)
    }

    /// Moves the complete temporary file into place, off the main actor;
    /// returns where it landed. Throws when it cannot land without
    /// overwriting a file the person did not choose. Either way the
    /// temporary file is deleted and the name freed, as `discard` does.
    public func finish() async throws -> URL {
        guard !settled else { return finalURL }
        settled = true
        let landed = await Self.land(temporaryURL, chosen: chosen, finalURL: finalURL, name: landingName,
                                     held: reservations.held)
        reservations.remove(finalURL)
        reservations.tempFiles?.remove(temporaryURL)
        if chosen == nil, case .success(let url) = landed { finalURL = url }
        return try landed.get()
    }

    /// The landing's file calls: the replace or the exclusive rename, then
    /// the next free name while one is in the way (a name another download
    /// held at the start, `held`, is skipped), then the temporary file's
    /// leftovers are deleted. Off the main actor: a replace or a rename on a
    /// slow or network volume blocks.
    @concurrent nonisolated private static func land(_ temporaryURL: URL, chosen: URL?, finalURL: URL, name: String,
                                                     held: Set<String>) async -> Result<URL, any Error> {
        defer {
            for url in [temporaryURL, temporaryURL.appendingPathExtension("crdownload")] {
                try? FileManager.checked.removeItem(at: url)
            }
        }
        if let chosen {
            return Result {
                if DownloadDestination.entryExists(chosen) {
                    _ = try FileManager.checked.replaceItemAt(chosen, withItemAt: temporaryURL)
                } else {
                    try moveExclusively(temporaryURL, to: chosen)
                }
                return chosen
            }
        }
        let directory = finalURL.deletingLastPathComponent()
        var target = finalURL
        // Each failed attempt found a new file in the way; give up (never
        // overwrite) after as many attempts as names `uniqueURL` tries.
        for _ in 0..<DownloadDestination.collisionLimit {
            do {
                try moveExclusively(temporaryURL, to: target)
                return .success(target)
            } catch let error as POSIXError where error.code == .EEXIST {
                // Taken since the download started: the next free name.
                guard let next = DownloadDestination.uniqueURL(in: directory, suggestedFilename: name, exists: {
                    DownloadDestination.entryExists($0) || held.contains(BrowserDownloadReservations.key($0))
                }) else { return .failure(error) }
                target = next
            } catch {
                return .failure(error)
            }
        }
        return .failure(POSIXError(.EEXIST))
    }

    /// The download failed or was cancelled (or has landed): deletes the
    /// temporary file and frees the name.
    public func discard() {
        guard !settled else { return }
        settled = true
        reservations.remove(finalURL)
        for url in [temporaryURL, temporaryURL.appendingPathExtension("crdownload")] {
            try? FileManager.default.removeItem(at: url)
        }
        reservations.tempFiles?.remove(temporaryURL)
    }

    /// `renamex_np(RENAME_EXCL)`: fails with EEXIST when anything (a file,
    /// a dangling symlink) is at `destination`; never follows or replaces it.
    nonisolated static func moveExclusively(_ source: URL, to destination: URL) throws {
        let result = renamex_np(source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL))
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// `<name>.<8 hex>.cmuxdownload` next to `file`, short enough for
    /// Chromium's `.crdownload` on top.
    static func temporarySibling(of file: URL) -> URL {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let suffix = ".\(tag).cmuxdownload"
        let room = DownloadDestination.maxNameBytes - DownloadDestination.fileSystemBytes(suffix + ".crdownload")
        let name = DownloadDestination.capped(file.lastPathComponent, bytes: room) + suffix
        return file.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
    }
}
