@testable import CmuxNextTerminal
import Foundation
import Testing

/// The first terminal surface's launch prefetch (`TerminalLaunchPrefetch`) and the split of
/// surface creation into phases (`SurfaceCreationPhases`, `first_surface.*` in `debug.timings`).
struct TerminalLaunchPrefetchTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "terminal-prefetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func familiesFollowTheConfigFilesInOrderAndAnEmptyValueClears() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "config")
        let second = directory.appending(path: "config.ghostty")
        try "font-family = Menlo\nfont-family = \"Fira Code\"\n".write(to: first, atomically: true, encoding: .utf8)
        try "# font-family = Ignored\nfont-family = \"\"\nfont-family = Iosevka\n".write(to: second, atomically: true, encoding: .utf8)
        let missing = directory.appending(path: "absent").path

        #expect(TerminalLaunchPrefetch.families(inFiles: [first.path, missing]) == ["Menlo", "Fira Code"])
        #expect(TerminalLaunchPrefetch.families(inFiles: [first.path, missing, second.path]) == ["Iosevka"])
    }

    @Test func theConfigOverrideIsTheOnlyFileRead() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let override = directory.appending(path: "override").path
        let environment = ["CMUX_NEXT_GHOSTTY_CONFIG": override, "XDG_CONFIG_HOME": directory.path]
        #expect(TerminalLaunchPrefetch.configFiles(environment: environment) == [override])
        let defaults = TerminalLaunchPrefetch.configFiles(environment: ["XDG_CONFIG_HOME": directory.path])
        #expect(defaults.first == directory.appending(path: "ghostty/config").path)
    }

    @Test func familiesAreDedupedAndCapped() {
        let prefetch = TerminalLaunchPrefetch(fontFamilies: ["A", "", "A", "B", "C", "D", "E"])
        #expect(prefetch.fontFamilies == ["A", "B", "C", "D"])
    }

    @Test func zeroTurnsThePrefetchOff() {
        #expect(TerminalLaunchPrefetch.isEnabled(environment: [:]))
        #expect(TerminalLaunchPrefetch.isEnabled(environment: ["CMUX_NEXT_TERMINAL_PREFETCH": "1"]))
        #expect(!TerminalLaunchPrefetch.isEnabled(environment: ["CMUX_NEXT_TERMINAL_PREFETCH": "0"]))
    }

    /// The launch runs it on a background thread; so does this test.
    @Test func runsOffTheMainThreadAndMarksEachPart() async {
        let prefetch = TerminalLaunchPrefetch(fontFamilies: ["Menlo", "No Such Family 7f3a"])
        let marks = await Task.detached {
            var marks: [String] = []
            prefetch.run { marks.append($0) }
            return marks
        }.value
        #expect(marks == ["terminal_prefetch.metal", "terminal_prefetch.fonts"])
    }

    @MainActor
    @Test func phasesSplitTheCreationAtEachMark() {
        let start = ContinuousClock.now
        var phases = SurfaceCreationPhases(start: start)
        phases.mark("runtime", at: start.advanced(by: .milliseconds(3)))
        phases.mark("surface_new", at: start.advanced(by: .milliseconds(10)))
        #expect(phases.phases.map { $0.name } == ["runtime", "surface_new"])
        #expect(phases.phases.map { $0.duration } == [.milliseconds(3), .milliseconds(7)])
    }

    @MainActor
    @Test func onlyTheFirstSurfaceLandsInTheRuntimePhases() {
        let start = ContinuousClock.now
        var phases = SurfaceCreationPhases(start: start)
        phases.mark("surface_new", at: start.advanced(by: .milliseconds(5)))
        TerminalTimings.surfaceCreated(.milliseconds(5), phases: phases)
        TerminalTimings.surfaceCreated(.milliseconds(5), phases: phases)
        let recorded = TerminalTimings.runtimePhases.filter { $0.name == "first_surface.surface_new" }
        #expect(recorded.count == 1)
    }
}
