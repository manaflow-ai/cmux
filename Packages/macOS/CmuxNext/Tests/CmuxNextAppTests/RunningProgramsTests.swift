@testable import CmuxNextApp
import CmuxNextAppCore
@testable import CmuxNextDaemon
import Testing

/// A close asks each closing terminal what it runs once; its undo toast
/// decision reuses those answers when they cover every terminal it needs.
@MainActor
@Suite struct RunningProgramsTests {
    @Test func namesAreUniqueSortedAndSkipShellOnlyTerminals() {
        let asked: RunningPrograms = [SurfaceID(rawValue: 1): "vim", SurfaceID(rawValue: 2): String?.none,
                                      SurfaceID(rawValue: 3): "cargo", SurfaceID(rawValue: 4): "vim"]
        #expect(asked.programNames == ["cargo", "vim"])
    }

    @Test func coversOnlyWhenEveryTerminalWasAsked() {
        let one = TabModel(TabSnapshot(surface: 1)), two = TabModel(TabSnapshot(surface: 2))
        let asked: RunningPrograms = [SurfaceID(rawValue: 1): String?.none]
        #expect(asked.covers([one]))
        #expect(!asked.covers([one, two]))
        #expect(!RunningPrograms().covers([one]))
    }
}
