import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "does the iPhone now, like, just do the projection? Like
/// it calculates it itself and it's all, like, identical, or I mean, like,
/// better than before maybe?" and "when i load in it show me uncompact then
/// squish well iphone should do more work it lazy relaxing!?"
///
/// The sizing harness: a Mac pane of 120x40 under "Fit the smallest viewer"
/// (`MacPaneMockSession`), a shell on its primary screen, and the session the
/// app builds for it (`TerminalSessionChoice.session(live:)`). The page goes
/// through attach, an app switch, a short and a long lock, a rotation and back
/// with the size claims the page makes (`TerminalSizeClaimDebounce`, the
/// production delays, on a synthetic clock). Per step it counts:
/// - Mac PTY resizes (SIGWINCHes the program got);
/// - wide frames: grids the page was told whose columns are not the phone's
///   (the Mac's 120 columns drawn on a phone: "uncompact");
/// - resets: the page's mirror starting over (a replay to lay out again).
/// Run at the base and at the head of the projection PR: the same numbers
/// go in its table.
@MainActor
@Suite(.serialized) struct TerminalProjectionResizeHarnessTests {
    typealias Debounce = TerminalSizeClaimDebounce<ContinuousClock.Instant>

    /// What the page was told.
    @MainActor final class Page {
        var phoneColumns = 0
        var alternate = false
        var wideFrames = 0
        var resets = 0
        var bytes = 0

        func take(_ event: TerminalSessionEvent) {
            switch event {
            case .output(let data):
                if data == TerminalReclaimHold.reset { resets += 1 } else { bytes += data.count }
            case .alternateScreen(let on):
                alternate = on
            case .hostGrid(let columns, _):
                if !alternate, columns != phoneColumns { wideFrames += 1 }
            default:
                break
            }
        }
    }

    struct Step: CustomStringConvertible {
        let name: String
        let macResizes: Int
        let wideFrames: Int
        let resets: Int
        var description: String { "\(name): mac PTY resizes \(macResizes), wide frames \(wideFrames), resets \(resets)" }
    }

    /// The lifecycle, as the page drives its session.
    static func run() -> (steps: [Step], mac: MacPaneMockSession, bytes: Int) {
        let mac = MacPaneMockSession(columns: 120, rows: 40)
        let session = TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: "zsh")
        let page = Page()
        var claim = Debounce(delay: Debounce.defaultDelay, backgroundDelay: Debounce.defaultBackgroundDelay)
        var now = ContinuousClock.now
        var steps: [Step] = []
        var last = (resizes: 0, wide: 0, resets: 0)
        func settle(_ name: String) {
            steps.append(Step(name: name, macResizes: mac.ptyResizes - last.resizes, wideFrames: page.wideFrames - last.wide,
                              resets: page.resets - last.resets))
            last = (mac.ptyResizes, page.wideFrames, page.resets)
        }
        func advance(_ duration: Duration) {
            // The claim's release timer firing on the way, as the claimer's task does.
            let end = now.advanced(by: duration)
            while true {
                let (change, recheck) = claim.update(at: now)
                if let change { session.setClaimsSize(change) }
                guard let recheck, recheck <= end else { break }
                now = recheck
            }
            now = end
            if let change = claim.update(at: now).claims { session.setClaimsSize(change) }
        }
        func grid(_ columns: Int, _ rows: Int) {
            page.phoneColumns = columns
            session.resize(columns: columns, rows: rows)
        }

        // Attach: the page measures its grid, shows, and the session starts.
        page.phoneColumns = 54
        claim.pageShown = true
        advance(.zero)
        grid(54, 38)
        session.start { page.take($0) }
        settle("attach")

        claim.appActive = false
        advance(.seconds(3))
        claim.appActive = true
        advance(.zero)
        settle("app switch (3 s)")

        claim.appActive = false
        advance(.seconds(20))
        claim.appActive = true
        advance(.zero)
        settle("lock (20 s)")

        claim.appActive = false
        advance(.seconds(600))
        claim.appActive = true
        advance(.zero)
        settle("lock (10 min)")

        // The soft keyboard: the page insets its rows and sends no grid (#41895).
        settle("keyboard toggle")

        grid(116, 16)
        settle("rotate to landscape")
        grid(54, 38)
        settle("rotate back")

        claim.pageShown = false
        advance(.seconds(2))
        claim.pageShown = true
        advance(.zero)
        settle("another tab and back")
        return (steps, mac, page.bytes)
    }

    @Test func aPrimaryScreenSessionNeverResizesTheMac() {
        let (steps, mac, _) = Self.run()
        for step in steps { print("projection harness: \(step)") }
        print("projection harness: total mac PTY resizes \(mac.ptyResizes) (\(mac.resizeLog.joined(separator: ", "))), claims sent \(mac.claimChanges)")
        for step in steps {
            #expect(step.macResizes == 0, "\(step)")
            #expect(step.wideFrames == 0, "\(step)")
        }
        #expect(mac.ptyResizes == 0, "the Mac pane kept 120x40: \(mac.resizeLog)")
        // Only the attach and the two rotations lay the page out.
        let resets = Dictionary(uniqueKeysWithValues: steps.map { ($0.name, $0.resets) })
        #expect(resets["app switch (3 s)"] == 0)
        #expect(resets["lock (20 s)"] == 0)
        #expect(resets["lock (10 min)"] == 0, "back from a long lock the page is already right")
        #expect(resets["keyboard toggle"] == 0)
        #expect(resets["another tab and back"] == 0)
    }
}
