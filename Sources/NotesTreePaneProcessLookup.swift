import Foundation

/// `ps -t` helper for pane↔process correlation. Agent processes survive app
/// relaunches and keep reporting their previous run's workspace/surface UUIDs
/// through hooks, so UUID matching misses them; the pane's TTY plus the
/// agent's live pid are current-run ground truth.
enum NotesTreePaneProcessLookup {
    typealias PaneProcess = NotesTreePaneProcess

    // Runs blocking `ps` pipe reads off the Swift cooperative executor;
    // this queue does not guard shared state.
    private static let processQueue = DispatchQueue(label: "com.cmux.notes.pane-process-lookup", qos: .utility)

    static func normalizeTTY(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst(5)) : trimmed
    }

    /// Map live pids to the (normalized) pane TTY they sit on.
    static func pidsByTTY(ttys: [String]) -> [Int: String] {
        Dictionary(
            paneProcesses(ttys: ttys).map { ($0.pid, $0.tty) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Every process on the given pane TTYs with its start time (derived from
    /// `ps` etime, locale-independent) and executable name.
    static func paneProcessesAsync(
        ttys: [String],
        now: TimeInterval = Date().timeIntervalSince1970
    ) async -> [PaneProcess] {
        await withCheckedContinuation { continuation in
            processQueue.async {
                continuation.resume(returning: paneProcesses(ttys: ttys, now: now))
            }
        }
    }

    /// Every process on the given pane TTYs with its start time (derived from
    /// `ps` etime, locale-independent) and executable name.
    static func paneProcesses(ttys: [String], now: TimeInterval = Date().timeIntervalSince1970) -> [PaneProcess] {
        let cleaned = Array(Set(ttys.map(normalizeTTY))).filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", cleaned.joined(separator: ","), "-o", "pid=,tty=,etime=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var result: [PaneProcess] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int(parts[0]) else { continue }
            let tty = normalizeTTY(String(parts[1]))
            guard let elapsed = parseElapsedTime(String(parts[2])) else { continue }
            // comm can contain spaces (path); take the basename of the joined rest.
            let command = ((parts[3...].joined(separator: " ") as NSString).lastPathComponent)
            result.append(PaneProcess(pid: pid, tty: tty, startedAt: now - elapsed, command: command))
        }
        return result
    }

    /// Parse `ps` etime ("[[dd-]hh:]mm:ss") into seconds.
    static func parseElapsedTime(_ value: String) -> TimeInterval? {
        var days = 0.0
        var rest = value
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = String(rest[rest.index(after: dash)...])
        }
        let fields = rest.split(separator: ":").map(String.init)
        guard (1...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let part = Double(field) else { return nil }
            seconds = seconds * 60 + part
        }
        return days * 86_400 + seconds
    }
}
