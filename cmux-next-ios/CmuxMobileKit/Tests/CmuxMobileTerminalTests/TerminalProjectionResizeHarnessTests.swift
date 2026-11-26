// The projection (TerminalProjectingSession) and its FFI are iOS only, so the
// harness runs on the kit job's iOS simulator leg, not under macOS swift test.
#if os(iOS)
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
    static func run(columns: Int = 120, rows: Int = 40) -> (steps: [Step], mac: MacPaneMockSession, bytes: Int) {
        let mac = MacPaneMockSession(columns: columns, rows: rows)
        let session = TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: "zsh")
        let page = Page()
        // The production delays (whatever the background grace is, or none).
        var claim = Debounce()
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

    /// Leo, 2026-11-17: "Surely we can just calculate a f***ing terminal and
    /// resize whatever needs exceptions when it comes / Fall back if need be".
    ///
    /// htop already running in a Mac pane of 120x40: the phone attaches into
    /// it, switches apps, locks, rotates and goes to another tab and back.
    /// None of it resizes the Mac: the page shows the Mac's grid (zoomed by
    /// the screen). Typing into htop, quitting it and starting it again
    /// resize nothing either (Leo, 2026-11-25: "do everything at parity on
    /// the phone").
    @Test func theAlternateScreenIsShownAtTheMacsGridAndNothingResizesTheMac() {
        let mac = MacPaneMockSession(columns: 120, rows: 40, program: "htop")
        let session = TerminalProjectingSession(inner: mac)
        var grids: [(columns: Int, alternate: Bool)] = []
        var alternate = false
        var claim = Debounce()
        var clock = ContinuousClock.now
        func advance(_ duration: Duration) {
            let end = clock.advanced(by: duration)
            while true {
                let (change, recheck) = claim.update(at: clock)
                if let change { session.setClaimsSize(change) }
                guard let recheck, recheck <= end else { break }
                clock = recheck
            }
            clock = end
            if let change = claim.update(at: clock).claims { session.setClaimsSize(change) }
        }
        var steps: [String] = []
        var lastResizes = 0
        var lastReplay = 0
        func settle(_ name: String) -> Int {
            let resizes = mac.ptyResizes - lastResizes
            steps.append("\(name): mac PTY resizes \(resizes), replay bytes \(mac.replayBytes - lastReplay)")
            lastResizes = mac.ptyResizes
            lastReplay = mac.replayBytes
            return resizes
        }
        claim.pageShown = true
        advance(.zero)
        session.resize(columns: 54, rows: 38)
        session.start { event in
            switch event {
            case .alternateScreen(let on): alternate = on
            case .hostGrid(let columns, _): grids.append((columns, alternate))
            default: break
            }
        }
        var viewing: [String: Int] = [:]
        viewing["attach into htop"] = settle("attach into htop")
        claim.appActive = false
        advance(.seconds(3))
        claim.appActive = true
        advance(.zero)
        viewing["app switch (3 s)"] = settle("app switch (3 s)")
        claim.appActive = false
        advance(.seconds(600))
        claim.appActive = true
        advance(.zero)
        viewing["lock (10 min)"] = settle("lock (10 min)")
        session.resize(columns: 116, rows: 16)
        viewing["rotate to landscape"] = settle("rotate to landscape")
        session.resize(columns: 54, rows: 38)
        viewing["rotate back"] = settle("rotate back")
        claim.pageShown = false
        advance(.seconds(2))
        claim.pageShown = true
        advance(.zero)
        viewing["another tab and back"] = settle("another tab and back")
        session.send(Data("\u{1B}[B\u{1B}[B".utf8))
        viewing["arrow keys"] = settle("arrow keys")
        session.send(Data("abc".utf8))
        let typed = settle("type abc into htop")
        let typedColumns = grids.last?.columns
        session.send(Data("q".utf8))
        let quit = settle("q (htop exits)")
        let before = grids.count
        session.send(Data("htop\r".utf8))
        let again = settle("htop again (remembered)")
        let macGridFrames = grids.dropFirst(before).filter { $0.alternate && $0.columns == 120 }.count
        for step in steps { print("projection harness altproj: \(step)") }
        print("projection harness altproj: total mac PTY resizes \(mac.ptyResizes) (\(mac.resizeLog.joined(separator: ", "))), claims sent \(mac.claimChanges), htop frames at the Mac's grid before the remembered fit \(macGridFrames)")
        for (name, resizes) in viewing {
            #expect(resizes == 0, "\(name) resized the Mac: \(mac.resizeLog)")
        }
        #expect(typed == 0, "typing into htop resized the Mac: \(mac.resizeLog)")
        #expect(typedColumns == 120, "htop stays at the Mac's columns, scaled: \(grids)")
        #expect(quit == 0, "htop exiting resized the Mac: \(mac.resizeLog)")
        #expect(again == 0, "htop again resized the Mac: \(mac.resizeLog)")
        #expect(mac.ptyResizes == 0, "the Mac pane kept 120x40: \(mac.resizeLog)")
        #expect(macGridFrames >= 1, "htop again shows at the Mac's grid: \(grids)")
    }

    /// Leo, 2026-11-15: "i dont see the point of a narrower-than-iphone
    /// terminal". A Mac pane of 39x26, narrower than the phone: every grid the
    /// page is told is the phone's own (54 columns, 116 in landscape), never
    /// the pane's 39, and the Mac pane is never resized.
    @Test func aMacPaneNarrowerThanThePhoneIsShownAtThePhonesWidth() {
        let (steps, mac, bytes) = Self.run(columns: 39, rows: 26)
        for step in steps { print("projection harness 39x26: \(step)") }
        for step in steps {
            #expect(step.macResizes == 0, "\(step)")
            #expect(step.wideFrames == 0, "a grid other than the phone's: \(step)")
        }
        #expect(mac.ptyResizes == 0, "the Mac pane kept 39x26: \(mac.resizeLog)")
        #expect(bytes > 0, "the page got the shell's text")
    }
}

#endif
