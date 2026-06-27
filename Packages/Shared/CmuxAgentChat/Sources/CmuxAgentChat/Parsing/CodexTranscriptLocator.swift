public import Foundation

/// Locates Codex rollout transcripts using bounded, metadata-backed matching.
///
/// The locator scans recent `~/.codex/sessions/YYYY/MM/DD` day directories,
/// plus the sessions root for legacy flat files, and verifies candidates with
/// ``CodexTranscriptIdentityMatcher`` before returning a path.
public struct CodexTranscriptLocator: Sendable {
    /// Default number of past day directories included in the lookup window.
    public static let defaultDayLookback = 14

    /// Default number of future day directories included for timezone skew.
    public static let defaultFutureDayLookahead = 1

    /// Default cap on JSONL files opened during a single transcript lookup.
    public static let defaultMaxCandidateFiles = 2_000

    private let dayLookback: Int
    private let futureDayLookahead: Int
    private let maxCandidateFiles: Int
    private let matcher: CodexTranscriptIdentityMatcher

    /// Creates a Codex transcript locator.
    ///
    /// - Parameters:
    ///   - dayLookback: Number of past day directories to scan.
    ///   - futureDayLookahead: Number of future day directories to scan.
    ///   - maxCandidateFiles: Maximum JSONL files opened per lookup.
    ///   - matcher: Metadata matcher used to verify candidate rollout files.
    public init(
        dayLookback: Int = Self.defaultDayLookback,
        futureDayLookahead: Int = Self.defaultFutureDayLookahead,
        maxCandidateFiles: Int = Self.defaultMaxCandidateFiles,
        matcher: CodexTranscriptIdentityMatcher = CodexTranscriptIdentityMatcher()
    ) {
        self.dayLookback = max(0, dayLookback)
        self.futureDayLookahead = max(0, futureDayLookahead)
        self.maxCandidateFiles = max(1, maxCandidateFiles)
        self.matcher = matcher
    }

    /// Returns the matching Codex transcript path, when one is found.
    ///
    /// - Parameters:
    ///   - sessionID: The confirmed Codex session id.
    ///   - sessionsURL: The `.codex/sessions` directory.
    ///   - fileManager: File manager used for directory and file access.
    ///   - now: Reference date for the bounded day-directory window.
    /// - Returns: Absolute path to the newest matching transcript, or `nil`.
    public func transcriptPath(
        sessionID: String,
        sessionsURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> String? {
        transcriptURL(
            sessionID: sessionID,
            sessionsURL: sessionsURL,
            fileManager: fileManager,
            now: now
        )?.path
    }

    /// Returns the matching Codex transcript URL, when one is found.
    ///
    /// - Parameters:
    ///   - sessionID: The confirmed Codex session id.
    ///   - sessionsURL: The `.codex/sessions` directory.
    ///   - fileManager: File manager used for directory and file access.
    ///   - now: Reference date for the bounded day-directory window.
    /// - Returns: URL to the newest matching transcript, or `nil`.
    public func transcriptURL(
        sessionID: String,
        sessionsURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> URL? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        var scannedFileCount = 0
        for directoryURL in recentSessionDirectories(
            sessionsURL: sessionsURL,
            fileManager: fileManager,
            now: now
        ) {
            guard scannedFileCount < maxCandidateFiles else {
                return nil
            }
            let candidates = jsonlCandidates(
                in: directoryURL,
                fileManager: fileManager,
                limit: maxCandidateFiles - scannedFileCount
            )
            for candidate in candidates {
                scannedFileCount += 1
                guard matcher.transcript(at: candidate, matchesSessionID: normalizedSessionID) else {
                    continue
                }
                return candidate
            }
        }
        return nil
    }

    private func recentSessionDirectories(
        sessionsURL: URL,
        fileManager: FileManager,
        now: Date
    ) -> [URL] {
        var directories: [URL] = []
        var seenPaths = Set<String>()

        func appendIfDirectory(_ url: URL) {
            guard seenPaths.insert(url.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            directories.append(url)
        }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let calendars = [Calendar.current, utcCalendar]
        for dayOffset in stride(from: futureDayLookahead, through: -dayLookback, by: -1) {
            for calendar in calendars {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
                    continue
                }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day else {
                    continue
                }
                appendIfDirectory(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                )
            }
        }

        appendIfDirectory(sessionsURL)
        return directories
    }

    private func jsonlCandidates(
        in directoryURL: URL,
        fileManager: FileManager,
        limit: Int
    ) -> [URL] {
        guard limit > 0 else { return [] }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var candidates: [URL] = []
        for url in urls where url.pathExtension == "jsonl" {
            insertCandidate(url, into: &candidates, limit: limit)
        }
        return candidates
    }

    private func insertCandidate(_ url: URL, into candidates: inout [URL], limit: Int) {
        let candidateName = url.lastPathComponent
        let insertionIndex = candidates.firstIndex {
            candidateName > $0.lastPathComponent
        } ?? candidates.endIndex
        guard insertionIndex < limit else {
            return
        }
        candidates.insert(url, at: insertionIndex)
        if candidates.count > limit {
            candidates.removeLast()
        }
    }
}
