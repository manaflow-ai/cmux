import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Darwin
import Foundation
import Testing

/// cmux#63767 with real processes: the staged build's pre-warm runs from Sparkle's staging folder, and a cancel (which
/// removes the folder) or an install (which moves it) must find every process of the pre-warm's groups exited. The
/// stand-in staged bundle's app handles SIGTERM with a slow shutdown, as Chromium's browser process does, and keeps a
/// child in its group; its `cmux-tui` takes SIGTERM's default. The check runs where Sparkle goes on: inside Sparkle's
/// cancel, and right after the will-install hook returns. Each process's exit is timed from the stop
/// (`BENCH prewarm stop` lines).
@MainActor @Suite(.serialized) struct StagedUpdatePrewarmRealStopTests {
    enum Stop: String, CaseIterable, Sendable { case cancel, install }

    /// A process of the pre-warm, by its pid file (`<role>-<pid>`).
    struct Started: Hashable {
        let role: String
        let pid: pid_t
    }

    /// When each process exited (kqueue NOTE_EXIT, not a poll), and which still ran when Sparkle went on.
    @MainActor final class Watch {
        var exits: [Started: ContinuousClock.Instant] = [:]
        var aliveWhenSparkleWentOn: [Started]?
        var sources: [any DispatchSourceProcess] = []
    }

    /// Whether `pid` still runs code: a zombie (exited, not yet reaped) or a pid that is gone does not.
    nonisolated static func runs(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return info.pbi_status != 5  // SZOMB
    }

    /// The stand-in staged bundle of build 200 under `installation`, as Sparkle 2 stages it (`<unique>/<unique>/X.app`).
    static func stage(in installation: URL, bundleIdentifier: String, pids: URL) throws {
        let app = installation.appending(path: "A1/B2/cmux NIGHTLY.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Resources/bin"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleVersion": "200", "CFBundleExecutable": "cmux"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        let dir = pids.path
        // The app: a child in its group, and a SIGTERM handler that takes a second to shut down (Chromium's does).
        let appScript = """
        #!/bin/sh
        sleep 30 &
        : > "\(dir)/child-$!"
        trap 'sleep 1; exit 0' TERM
        : > "\(dir)/app-$$"
        wait
        """
        // A bundled tool: SIGTERM's default action.
        let toolScript = """
        #!/bin/sh
        : > "\(dir)/tool-$$"
        exec sleep 30
        """
        for (path, body) in [("MacOS/cmux", appScript), ("Resources/bin/cmux-tui", toolScript)] {
            let url = app.appending(path: path)
            try Data(body.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func started(in pids: URL) -> Set<Started> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pids.path)) ?? []
        return Set(names.compactMap { name in
            let parts = name.split(separator: "-")
            guard parts.count == 2, let pid = pid_t(parts[1]) else { return nil }
            return Started(role: String(parts[0]), pid: pid)
        })
    }

    @Test(arguments: Stop.allCases)
    func everyPrewarmProcessHasExitedWhenSparkleGoesOn(_ stop: Stop) async throws {
        let bundleIdentifier = "com.cmuxterm.app.debug.prewarm-real-\(UUID().uuidString.prefix(8).lowercased())"
        let installation = UpdateInstallPreflight.stagedInstallation(bundleIdentifier: bundleIdentifier)
        let caches = installation.deletingLastPathComponent().deletingLastPathComponent()
        let pids = FileManager.default.temporaryDirectory.appending(path: "prewarm-real-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pids, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: caches)
            try? FileManager.default.removeItem(at: pids)
        }
        try Self.stage(in: installation, bundleIdentifier: bundleIdentifier, pids: pids)

        let updater = StagedUpdatePrewarmTests.updater(stagedBuild: "200", bundleIdentifier: bundleIdentifier)
        updater.frontmost = { UpdateFrontmostApp(isThisApp: false, pid: 1, bundleID: nil) }
        updater.keptRunningBuild = .kept  // the will-install hook keeps nothing of the test runner
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        try #require(await StagedUpdatePrewarmTests().eventually(.seconds(20)) {
            Set(Self.started(in: pids).map(\.role)) == ["app", "child", "tool"]
        }, "the pre-warm's processes did not start: \(updater.log.recent)")
        let processes = Self.started(in: pids)

        let watch = Watch()
        for process in processes {
            let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { if watch.exits[process] == nil { watch.exits[process] = .now } } }
            source.resume()
            watch.sources.append(source)
        }
        defer { watch.sources.forEach { $0.cancel() } }
        let goesOn = { watch.aliveWhenSparkleWentOn = processes.filter { Self.runs($0.pid) }.sorted { $0.role < $1.role } }

        let stopped = ContinuousClock.now
        switch stop {
        case .cancel:
            updater.cancelStaged = { goesOn(); return true }
            #expect(updater.cancelStagedUpdate())
        case .install:
            updater.updaterWillInstallUpdate(build: "200")
            goesOn()
        }
        let wentOn = ContinuousClock.now
        // Every process ends: by its own exit, SIGTERM, or SIGKILL after the 2 s grace.
        #expect(await StagedUpdatePrewarmTests().eventually(.seconds(10)) {
            processes.allSatisfy { watch.exits[$0] != nil || !Self.runs($0.pid) }
        }, "a pre-warm process outlived the stop")
        let ms = { (instant: ContinuousClock.Instant?) in
            instant.map { String(format: "%.1f", Double(($0 - stopped).components.attoseconds) / 1e15 + Double(($0 - stopped).components.seconds) * 1000) } ?? "?"
        }
        for process in processes.sorted(by: { $0.role < $1.role }) {
            print("BENCH prewarm stop (\(stop.rawValue)): \(process.role) exited \(ms(watch.exits[process])) ms after the stop; Sparkle went on at \(ms(wentOn)) ms")
        }
        let alive = watch.aliveWhenSparkleWentOn ?? []
        #expect(alive.isEmpty, "still running when Sparkle went on (\(stop.rawValue)): \(alive.map(\.role)); \(updater.log.recent)")
    }
}
