import CmuxNextCompat
import CmuxNextCrashReporting
import Foundation

extension AppRunMarker {
    /// The crash keys a run's crash path wrote (`url`: its `run.crashkeys`); nil when that run ended with no crash
    /// path (a normal quit, SIGKILL, power loss). Off the main thread.
    nonisolated static func readCrashKeys(_ url: URL) -> CrashKeys? {
        (try? String(blockingContentsOf: url, encoding: .utf8)).flatMap { CrashKeys(record: $0) }
    }

    /// `run.json`'s bytes for `marker` (about 120).
    nonisolated static func encode(_ marker: PreviousRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(marker)
    }
}
