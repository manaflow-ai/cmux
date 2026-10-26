import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's first-open warm-ups are afterStartup posts (p08-startup-016): nothing runs before
/// startup completes, then one per frame in post order, each a named startup record.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchFirstOpenWarmupsTests {
    @Test func eachWarmUpRunsAfterCompletionOnePerFrameInOrder() {
        let s = StartupTestScheduler()
        let ran = WarmupRan()
        s.startup.post(.afterFirstFrame, "AppServices.startNonPaintServices", on: .main) { ran.names.append("nonPaint") }
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0", "Palette.prepare.1"],
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
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0", "Palette.prepare.1"], preparePalette: { _ in },
                               prepareIconPicker: {}, warmOpenPanel: {}).post(on: s.startup)
        s.complete()
        for _ in 0..<4 { s.fire() }
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == ["Palette.prepare.0", "Palette.prepare.1", "IconPicker.prepare", "OpenPanel.warmWhenIdle"])
        #expect(records.allSatisfy { $0.priority == .afterStartup && $0.destination == .main && $0.violation == nil })
        #expect(records.allSatisfy { $0.durationNanos != nil }, "each ran after completion and is recorded")
    }

    @Test func aQuitBeforeCompletionRunsNoWarmUp() {
        let s = StartupTestScheduler()
        let ran = WarmupRan()
        LaunchFirstOpenWarmups(paletteSteps: ["Palette.prepare.0"], preparePalette: { ran.names.append("palette.\($0)") },
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
