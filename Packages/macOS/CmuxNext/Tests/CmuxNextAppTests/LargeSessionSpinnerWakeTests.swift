@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Which observations a change wakes in the `large` session (plans/cmux-next/main-thread-scheduling.md 1.5), checked by
/// its effect with `ObservationWakes`. No GUI timing: what a change wakes does not depend on the host. Each case takes
/// a ``SessionFixtureSize``: `CMUX_TEST_SESSION_SIZES=real` runs it on the person's 826 workspaces.
@MainActor @Suite(.serialized)
struct LargeSessionSpinnerWakeTests {
    private static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// (a) D2: a spinner-only title change wakes 0 observations. The agents (5 at `large`, 170 at `real`), each in its
    /// own hidden workspace, step their spinner 100 times each (`⠋ Fix the bug 1`, `⠙ Fix the bug 1`, ...): what a tab
    /// shows does not change, so nothing may wake.
    /// As Chrome steps a tab's throbber without touching its title (C7).
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func aSpinnerFrameWakesNoObservation(size: SessionFixtureSize) async throws {
        try await LargeSessionWindowFixture.withWindow(size) { store in
            let agents = LargeSessionWindowFixture.agents(size)
            for (index, surface) in agents.enumerated() {
                store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "⠂ Fix the bug \(index)", text: "Fix the bug \(index)", activity: "working"))
            }
            await LargeSessionWindowFixture.drainMain()

            let wakes = ObservationWakes()
            for frame in 0..<100 {
                ObservationWakes.$current.withValue(wakes) {
                    for (index, surface) in agents.enumerated() {
                        let glyph = Self.spinner[(frame + index) % Self.spinner.count]
                        store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "\(glyph) Fix the bug \(index)",
                                                                     text: "Fix the bug \(index)", activity: "working"))
                    }
                }
                await LargeSessionWindowFixture.drainMain() // woken observers re-arm before the next frame
            }
            for (site, count) in wakes.bySite.sorted(by: { $0.key < $1.key }) {
                print("spinner wakes \(site): \(count)")
            }
            #expect(wakes.count == 0, "\(100 * agents.count) spinner frames woke \(wakes.count) observations: \(wakes.bySite)")

            // The counter is wired: new words in the shown workspace's terminal wake its tab's observers.
            let control = ObservationWakes()
            ObservationWakes.$current.withValue(control) {
                store.apply(LargeSessionWindowFixture.titleChanged(LargeSessionWindowFixture.shown(size), raw: "vim notes.md", text: "vim notes.md", activity: nil))
            }
            #expect(control.count > 0, "fixture: a shown tab's new title woke no observation (the counter is not wired)")
        }
    }
}
