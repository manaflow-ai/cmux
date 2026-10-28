import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's first-open warm-ups are afterStartup posts: nothing runs before
/// startup completes, then one per frame in post order, each a named startup record; the palette's
/// string tables load before, on a lane at the first frame.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchFirstOpenWarmupsTests {
    @Test func eachWarmUpRunsAfterCompletionOnePerFrameInOrder() {
        let s = StartupTestScheduler()
        let ran = WarmupRan()
        s.startup.post(.afterFirstFrame, "AppServices.startNonPaintServices", on: .main) { ran.names.append("nonPaint") }
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0", "Palette.prepare.1"], prewarmPaletteStrings: {},
                               preparePalette: { ran.names.append("palette.\($0)") },
                               prepareIconPicker: { ran.names.append("iconPicker") },
                               warmOpenPanel: { ran.names.append("openPanel") }).post(on: s.startup)
        let restore = s.startup.hold("WindowManager.restore")
        s.complete()
        for _ in 0..<6 { s.fire() }
        #expect(ran.names == ["nonPaint"], "a warm-up ran before the visible panes showed their content")
        restore.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        #expect(s.startup.completion?.heldTasks == 4)
        var perFrame: [Int] = []
        for _ in 0..<5 {
            let before = ran.names.count
            s.fire()
            perFrame.append(ran.names.count - before)
        }
        #expect(ran.names == ["nonPaint", "palette.0", "palette.1", "iconPicker", "openPanel"])
        #expect(perFrame == [1, 1, 1, 1, 0], "one warm-up per idle frame")
    }

    @Test func debugStartupListsEachPaletteStepByName() {
        let s = StartupTestScheduler()
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0", "Palette.prepare.1"], prewarmPaletteStrings: {}, preparePalette: { _ in },
                               prepareIconPicker: {}, warmOpenPanel: {}).post(on: s.startup)
        s.complete()
        for _ in 0..<4 { s.fire() }
        let records = s.startup.log.records
        #expect(records.map(\.name.description)
            == ["Palette.prewarmStrings", "Palette.prepare.0", "Palette.prepare.1", "IconPicker.prepare", "OpenPanel.warmWhenIdle"])
        let main = records.filter { $0.destination == .main }
        #expect(main.count == 4)
        #expect(main.allSatisfy { $0.priority == .afterStartup && $0.violation == nil })
        #expect(main.allSatisfy { $0.durationNanos != nil }, "each ran after completion and is recorded")
    }

    /// The palette's string tables load on the files lane once the first frame
    /// committed, while startup is still held open, so no prepare step (and no open before
    /// completion) reads them first on main.
    @Test func thePaletteStringsLoadOffMainAtTheFirstFrameBeforeAnyPrepareStep() async {
        let s = StartupTestScheduler()
        let ran = WarmupRan()
        let (loaded, signal) = AsyncStream.makeStream(of: Void.self)
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0", "Palette.prepare.1"], prewarmPaletteStrings: { signal.yield() },
                               preparePalette: { ran.names.append("palette.\($0)") },
                               prepareIconPicker: { ran.names.append("iconPicker") },
                               warmOpenPanel: { ran.names.append("openPanel") }).post(on: s.startup)
        let restore = s.startup.hold("WindowManager.restore")
        let strings = s.startup.log.records.filter { $0.name.description == "Palette.prewarmStrings" }
        #expect(strings.count == 1)
        #expect(strings.allSatisfy { $0.priority == .afterFirstFrame && $0.destination == .lane(.files, .userVisible) && $0.violation == nil })
        #expect(strings.allSatisfy { $0.startNanos == nil }, "the strings loaded before the first frame")
        s.complete() // the first frame; the restore still holds startup open
        for await _ in loaded { break }
        #expect(s.startup.completion == nil, "the strings waited for startup to complete")
        #expect(ran.names.isEmpty, "a prepare step ran before the strings loaded")
        restore.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        for _ in 0..<5 { s.fire() }
        #expect(ran.names == ["palette.0", "palette.1", "iconPicker", "openPanel"])
    }

    @Test func aQuitBeforeCompletionRunsNoWarmUp() {
        let s = StartupTestScheduler()
        let ran = WarmupRan()
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0"], prewarmPaletteStrings: {}, preparePalette: { ran.names.append("palette.\($0)") },
                               prepareIconPicker: { ran.names.append("iconPicker") },
                               warmOpenPanel: { ran.names.append("openPanel") }).post(on: s.startup)
        s.startup.beginQuit()
        s.complete()
        for _ in 0..<4 { s.fire() }
        #expect(ran.names.isEmpty)
    }
}

@MainActor
private final class WarmupRan {
    var names: [String] = []
}
