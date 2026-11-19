import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation

/// Experiment arm E (lane/rtc-premain-e, not for merge): after Chromium starts (and makes its code-sign clone, which
/// hard-links this app's main executable), runs the main executable with `--cmux-prewarm-launch` (it exits at the
/// top of main) three times, 1 s apart, printing how long each exec took and whether the clone folder had entries.
nonisolated struct ExecPolicyPrewarm {
    static func start() {
        guard let executable = Bundle.main.executableURL, let bundleID = Bundle.main.bundleIdentifier else { return }
        Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
            FileHandle.standardOutput.write(Data("EXEC-STAT at_ready \(exeStat(executable.path))\n".utf8))
            for attempt in 1...3 {
                // wakeup-allow: experiment, three one-shot waits after Chromium starts
                try? await Task.sleep(for: .seconds(1))
                let clones = cloneEntries(bundleID: bundleID)
                let started = Date()
                let ended: Date = await withCheckedContinuation { continuation in
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["--cmux-prewarm-launch"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { _ in continuation.resume(returning: Date()) }
                    do { try process.run() } catch { continuation.resume(returning: Date()) }
                }
                let ms = String(format: "%.0f", ended.timeIntervalSince(started) * 1_000)
                FileHandle.standardOutput.write(Data("EXEC-PREWARM attempt=\(attempt) ms=\(ms) clone_entries_before=\(clones) \(exeStat(executable.path))\n".utf8))
            }
        }
    }

    /// The main executable's link count and how long ago its inode last changed (ctime).
    static func exeStat(_ path: String) -> String {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return "stat_failed" }
        let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        let age = String(format: "%.0f", (Date().timeIntervalSince1970 - changed) * 1_000)
        return "nlink=\(info.st_nlink) ctime_age_ms=\(age)"
    }

    /// Entries in Chromium's code-sign clone folder for this bundle ($TMPDIR/../X/<bundle id>.code_sign_clone).
    static func cloneEntries(bundleID: String) -> Int {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
            .appending(path: "X").appending(path: bundleID + ".code_sign_clone")
        return (try? FileManager.checked.contentsOfDirectory(atPath: root.path).count) ?? -1
    }
}
