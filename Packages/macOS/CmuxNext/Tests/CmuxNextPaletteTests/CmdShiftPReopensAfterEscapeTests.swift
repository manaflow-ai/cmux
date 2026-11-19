import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P after an Escape opens the palette again, every time (perf gate rows
/// `palette.*_cmd_shift_p.key_to_frame`: one open timed out of six, p50 = p95, while Cmd-P timed six).
/// This probe tells where the Escape leaves the palette: visible, the model still open, or a close held.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
struct CmdShiftPReopensAfterEscapeTests {
    @Test func everyCmdShiftPAfterEscapeOpens() async {
        _ = NSApplication.shared
        let palette = PaletteController(registry: .standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.bindRegistryActions()
        palette.prepare(step: 0)
        palette.prepare(step: 1)
        var states: [String] = []
        for round in 0..<6 {
            #expect(palette.registry.perform("commandPalette"), "round \(round): Cmd-Shift-P's action did not run")
            let opened = palette.isVisible
            let handled = palette.model.handle(.escape)
            states.append("round \(round): opened=\(opened) escHandled=\(handled) visibleAfterEsc=\(palette.isVisible) pendingClose=\(palette.model.pendingClose)")
            await palette.model.settle()
            states.append("  settled: visible=\(palette.isVisible)")
        }
        let opens = states.filter { $0.contains("opened=true") }.count
        #expect(opens == 6, "Cmd-Shift-P opened \(opens) of 6 times:\n\(states.joined(separator: "\n"))")
        #expect(!states.contains { $0.contains("visibleAfterEsc=true") && !$0.contains("pendingClose=true") },
                "\(states.joined(separator: "\n"))")
    }
}
