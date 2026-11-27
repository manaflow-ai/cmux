import CoreServices
public import Foundation

/// The one download policy of both engines (WebKit's `WKDownload` path and
/// Chromium's `CEFDownloads`):
/// - a file goes only to the Downloads folder, under the page's suggested
///   name made safe and unique, or to the exact file the person chose in a
///   save panel; never to a path a page supplies;
/// - it is written to a temporary sibling and moves into place only when
///   it completes (`place`, `BrowserDownloadPlacement`): two downloads never
///   share a name, an existing file or symlink is never written through,
///   and a failed Save As keeps the old file;
/// - every finished file carries the macOS quarantine attribute, with the
///   address it came from;
/// - no finished file is ever opened.
public nonisolated struct BrowserDownloadPolicy: Sendable {
    public init() {}

    /// Why `place` found no file for a download.
    public enum PlaceFailure: Error, Equatable, Sendable {
        /// Every name up to `DownloadDestination.collisionLimit` is taken.
        case noFreeName
        /// macOS refused the app access to the folder (Files and Folders).
        case folderDenied

        /// The download's failure reason, as the downloads list shows it.
        public var reason: String {
            switch self {
            case .noFreeName: "no free file name"
            case .folderDenied: "no access to the downloads folder"
            }
        }
    }

    /// Where a download of either engine is written and lands
    /// (`BrowserDownloadPlacement`): `chosen` (a save panel's file), else a
    /// new file in `directory` named after `suggestedFilename`
    /// (`DownloadDestination.sanitizedFilename`, then ` (1)`, ` (2)`, ... on
    /// a collision), skipping names that other running downloads hold,
    /// written to a temporary sibling until it completes.
    ///
    /// The names are looked up (`probe`, an `lstat` each) off the main
    /// thread: the first look into a folder macOS protects (Downloads)
    /// waits for the person's answer to its access prompt, and on the main
    /// thread that froze the whole app, every tab and the control socket,
    /// until someone answered (a fleet Mac: never). A folder macOS refuses
    /// fails at its first look, not after `collisionLimit` refused ones.
    ///
    /// Before any name, one write in `directory` (`mayWrite`, also off the
    /// main thread): a look at a name that is not there does not ask for
    /// access, and the engine then asked on the main thread (WebKit issues
    /// the file's sandbox extension there), freezing the app the same way.
    @MainActor
    public static func place(chosen: URL?, suggestedFilename: String, directory: URL,
                             reservations: BrowserDownloadReservations = .shared,
                             probe: @escaping @Sendable (URL) -> DownloadDestination.Entry = DownloadDestination.entry(at:),
                             mayWrite: @escaping @Sendable (URL) -> Bool = DownloadDestination.mayWrite(in:))
        async -> Result<BrowserDownloadPlacement, PlaceFailure> {
        // The save panel already asked before replacing the chosen file.
        if let chosen { return .success(BrowserDownloadPlacement(finalURL: chosen, chosen: chosen, reservations: reservations)) }
        guard await Task.detached(priority: .userInitiated, operation: { mayWrite(directory) }).value else {
            return .failure(.folderDenied)
        }
        // Another download can take a name while this one looks: look again
        // with the names held now (a bounded number of times).
        for _ in 0..<8 {
            let held = reservations.heldPaths
            let found = await Task.detached(priority: .userInitiated) {
                firstFreeURL(in: directory, suggestedFilename: suggestedFilename, held: held, probe: probe)
            }.value
            switch found {
            case .failure(let failure): return .failure(failure)
            case .success(let url) where !reservations.contains(url):
                return .success(BrowserDownloadPlacement(finalURL: url, chosen: nil, reservations: reservations))
            case .success: continue
            }
        }
        return .failure(.noFreeName)
    }

    /// The first name in `directory` for `suggestedFilename` that `probe`
    /// finds free and no running download holds (`held`, standardized
    /// paths). Runs off the main thread.
    nonisolated static func firstFreeURL(in directory: URL, suggestedFilename: String, held: Set<String>,
                                         probe: (URL) -> DownloadDestination.Entry) -> Result<URL, PlaceFailure> {
        var denied = false
        let url = DownloadDestination.uniqueURL(in: directory, suggestedFilename: suggestedFilename) { candidate in
            if denied || held.contains(BrowserDownloadReservations.key(candidate)) { return true }
            switch probe(candidate) {
            case .absent: return false
            case .present: return true
            case .denied:
                denied = true
                return true
            }
        }
        if denied { return .failure(.folderDenied) }
        return url.map(Result.success) ?? .failure(.noFreeName)
    }

    /// What happens to a complete temporary file before it is published.
    public enum CompletionStep: Equatable, Sendable {
        /// Mark `file` as downloaded from `source` (Gatekeeper asks before
        /// it first opens).
        case quarantine(file: URL, source: URL?)
    }

    /// The pre-publication steps for a complete download: quarantine only.
    /// Opening the file is never a step.
    public static func completionSteps(destination: URL?, source: URL?) -> [CompletionStep] {
        destination.map { [.quarantine(file: $0, source: source)] } ?? []
    }

    /// The quarantine properties of a file downloaded from `source`
    /// (`kLSQuarantine*`, type web download).
    public static func quarantineProperties(source: URL?, agentName: String, agentBundleID: String?) -> [String: Any] {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: agentName,
        ]
        if let agentBundleID { properties[kLSQuarantineAgentBundleIdentifierKey as String] = agentBundleID }
        if let source, ["http", "https", "ftp"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        return properties
    }

    /// Writes the quarantine attribute (`com.apple.quarantine`) on `file`.
    public static func quarantine(_ file: URL, source: URL?, bundle: Bundle = .main) throws {
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "cmux"
        var values = URLResourceValues()
        values.quarantineProperties = quarantineProperties(source: source, agentName: name, agentBundleID: bundle.bundleIdentifier)
        var target = file
        try target.setResourceValues(values)
    }

    /// Runs every required step on the owned temporary file. A failure is
    /// propagated so the caller can discard it instead of publishing it.
    static func prepareForLanding(_ file: URL, source: URL?, quarantine: (URL, URL?) throws -> Void) throws {
        for step in completionSteps(destination: file, source: source) {
            switch step {
            case .quarantine(let file, let source):
                try quarantine(file, source)
            }
        }
    }
}
