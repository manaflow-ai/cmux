import CmuxNextHistory
import CryptoKit
public import Foundation

extension DaemonHistoryClient {
    /// Imports `log` (an app-local `History.sqlite`) into the daemon's store of `profile`, then deletes it and
    /// its SQLite side files once the daemon confirms the import committed. It throws the daemon's error, so
    /// the history's write queue retries a dropped link or timeout; a refusal leaves the file for the next launch.
    /// The key (path, size, time) makes a retry of the same file replay, and the daemon also records each
    /// imported file, so no session imports it twice.
    public func importLegacyLog(_ log: URL, supportDirectory: URL, profile: String) async throws {
        guard let source = LegacyHistoryFile(url: log, supportDirectory: supportDirectory) else { return }
        let sidecarURLs = ["-wal", "-shm"].map {
            URL(fileURLWithPath: source.url.path + $0)
        }
        var sidecars: [LegacyHistoryFile] = []
        var missing: [URL] = []
        for url in sidecarURLs {
            if LegacyHistoryFile.pathEntryExists(url) {
                guard let file = LegacyHistoryFile(url: url, supportDirectory: supportDirectory) else { return }
                sidecars.append(file)
            } else {
                missing.append(url)
            }
        }
        let captured = [source] + sidecars
        let identity = captured.map { "\($0.url.path)|\($0.fingerprint)" }
            + missing.map { "\($0.path)|missing" }
        let digest = SHA256.hash(data: Data(identity.joined(separator: "\n").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let key = "cmux-next-history-import-\(digest)"
        _ = try await importVisits(profile: profile, path: source.url.path, key: key)
        _ = LegacyHistoryFile.removeGenerationIfUnchanged(
            Array(sidecars.reversed()) + [source],
            missing: missing
        )
    }
}
