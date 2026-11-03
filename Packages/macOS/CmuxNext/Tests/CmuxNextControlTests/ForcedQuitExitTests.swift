import CmuxNextControl
import Testing

/// A second quit signal's exit (S4 review): it prepares, arms the deadline at its limit, saves, then ends,
/// once; a third signal starts nothing.
@MainActor
@Suite struct ForcedQuitExitTests {
    @Test func theExitRunsOnceInOrderAndAThirdSignalDoesNothing() async {
        var steps: [String] = []
        var limits: [Duration] = []
        let exit = ForcedQuitExit(prepare: { steps.append("prepare") },
                                  save: { steps.append("save") },
                                  armDeadline: { limits.append($0) },
                                  end: { steps.append("end") })
        let first = exit.start()
        #expect(exit.start() == nil, "a third signal started a second exit")
        await first?.value
        #expect(exit.start() == nil)
        #expect(steps == ["prepare", "save", "end"])
        #expect(limits == [.milliseconds(160)])
    }

    @Test func theDeadlineIsArmedBeforeTheSaveRuns() async {
        var armedBeforeSave: Bool?
        var armed = false
        let exit = ForcedQuitExit(prepare: {}, save: { armedBeforeSave = armed },
                                  armDeadline: { _ in armed = true }, end: {})
        await exit.start()?.value
        #expect(armedBeforeSave == true)
    }
}
