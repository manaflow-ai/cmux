import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// The daemon's tab of a New Terminal Tab (Ctrl-`) adopts its stand-in's terminal: the same entry, view, session and
/// input lane (review of 107f5da1ac6). Keys typed into the stand-in go to the daemon by its terminal id; a new view
/// for the daemon's tab closed the stand-in's lane with keys still in it, or sent its keys after the new view's.
@MainActor @Suite(.serialized)
struct StandInTerminalAdoptionTests {
    @Test func theDaemonsTabKeepsTheStandInsTerminal() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = services.cache.terminal(for: standIn, daemon: services.daemon)
        #expect(entry.gate != nil, "the stand-in's terminal attached before the daemon made it")

        let made = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 42), tabResourceID: ResourceID(rawValue: "tab_adopted42"),
                                        terminalID: terminal, kind: .pty))
        let adopted = services.cache.terminal(for: made, daemon: services.daemon)
        #expect(adopted === entry, "the daemon's tab made a new terminal instead of keeping the stand-in's")
        #expect(services.cache.existingTerminal(standIn.id) == nil, "the stand-in's entry stayed beside the daemon tab's")
        #expect(services.cache.existingTerminal(made.id) === entry)

        // Another tab (no stand-in chose its terminal id) gets its own terminal.
        let other = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 43), tabResourceID: ResourceID(rawValue: "tab_other43"),
                                         terminalID: TerminalID.generate(), kind: .pty))
        #expect(services.cache.terminal(for: other, daemon: services.daemon) !== entry)
        for key in [made.id, other.id] { services.cache.release(key) }
    }
}
