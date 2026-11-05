public import Foundation

/// The folder a download goes to when the person chose no file
/// (`DownloadDestination.defaultDirectory`, both engines).
///
/// The user's Downloads folder. In a Debug or bench build only, the folder that
/// the launch variable `CMUX_NEXT_DOWNLOADS_DIR` names, when it is an absolute
/// path: a fleet kit sets it to its own folder, so the app under test never
/// writes to the account's real Downloads folder (FileManager ignores the
/// step's HOME), where macOS asks for Files and Folders access in a prompt
/// that covers a capture Mac's screen. A Release build does not compile the
/// override and always uses the user's folder.
public nonisolated struct DownloadsFolder: Sendable, Equatable {
    /// The launch variable that moves downloads (Debug and bench builds only).
    public static let overrideKey = "CMUX_NEXT_DOWNLOADS_DIR"

    /// The folder.
    public let url: URL

    /// The folder of a process launched with `environment`: the override,
    /// else `userDownloads` (the override is unset, not an absolute path, or
    /// compiled out in Release). The folder must exist; nothing here touches
    /// the disk.
    public init(environment: [String: String], userDownloads: URL) {
        url = Self.override(in: environment) ?? userDownloads
    }

    /// This process's folder, from its launch environment, read once (a
    /// static `let`), never per download.
    public static let launch = DownloadsFolder(environment: ProcessInfo.processInfo.environment,
                                               userDownloads: userDownloads)

    /// The user's Downloads folder.
    public static var userDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    private static func override(in environment: [String: String]) -> URL? {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let path = environment[overrideKey], path.hasPrefix("/") else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        #else
        return nil
        #endif
    }
}
