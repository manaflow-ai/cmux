@testable import CmuxNextApp
import Foundation
import Testing

/// p06-scheduler-301: a Ghostty config save reloads once, after the 75 ms debounce, which is a `MainDeadline` on the
/// app's deadline scheduler (`MainDeadlineRig`: its uptime moves only when the rig fires a wake), and the file event's
/// hop to main is a posted task; after `stop()` a save reloads nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct GhosttyConfigLiveReloadTests {
    final class Reloads {
        var count = 0
    }

    @Test func aSaveReloadsOnceAfterTheDebounceOnTheAppsDeadlineScheduler() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-ghostty-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        let rig = MainDeadlineRig()
        let reloads = Reloads()
        let live = GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { [file.path] }, reload: { reloads.count += 1 },
                                           onConfigChange: { _ in })
        live.start()
        // The watch arms off main: save until one event has reached main and its debounce fired.
        let end = Date(timeIntervalSinceNow: 5)
        var saves = 0
        while reloads.count == 0, Date() < end {
            saves += 1
            try Data("font-size = \(12 + saves)\n".utf8).write(to: file)
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            rig.fireAndRun()
        }
        #expect(reloads.count == 1, "a save reloads the config once")
        #expect(rig.elapsed >= 0.075, "the reload waited the 75 ms debounce on the app's deadline scheduler")

        live.stop()
        try Data("font-size = 99\n".utf8).write(to: file)
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        rig.fireAndRun()
        rig.fireAndRun()
        #expect(reloads.count == 1, "a stopped watch reloads nothing")
    }
}
