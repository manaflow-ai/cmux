import CoreServices
public import Foundation

/// The one download policy of both engines (WebKit's `WKDownload` path and
/// Chromium's `CEFDownloads`):
/// - a file goes only to the Downloads folder, under the page's suggested
///   name made safe and unique, or to the exact file the person chose in a
///   save panel; never to a path a page supplies;
/// - every finished file carries the macOS quarantine attribute, with the
///   address it came from;
/// - no finished file is ever opened.
public nonisolated enum BrowserDownloadPolicy {
    /// Where a download goes: `chosen` (a save panel's file), else a new
    /// file in `directory` named after `suggestedFilename`
    /// (`DownloadDestination.sanitizedFilename`, then ` (1)`, ` (2)`, ... on
    /// a collision).
    public static func destination(chosen: URL?, suggestedFilename: String, directory: URL,
                                   exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL {
        chosen ?? DownloadDestination.uniqueURL(in: directory, suggestedFilename: suggestedFilename, exists: exists)
    }

    /// What happens to a finished file.
    public enum CompletionStep: Equatable, Sendable {
        /// Mark `file` as downloaded from `source` (Gatekeeper asks before
        /// it first opens).
        case quarantine(file: URL, source: URL?)
    }

    /// The steps for a finished download: quarantine only. Opening the
    /// file is never a step.
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

    @MainActor
    static func runCompletionSteps(for download: BrowserDownload) {
        for step in completionSteps(destination: download.destination, source: download.sourceURL) {
            switch step {
            case .quarantine(let file, let source):
                try? quarantine(file, source: source)
            }
        }
    }
}
