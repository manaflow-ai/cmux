import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "if I do completely switch away, I want to be gone. I
/// want to leave it. And if I come back, I don't want to see the stretched
/// out version. I want to see the actual version."
///
/// The full-screen app's size claim on leaving: a Mac pane of 120x40 under
/// "Fit the smallest viewer" (`MacPaneMockSession`) running a vim-style app
/// on the alternate screen, through the session the app builds
/// (`TerminalSessionChoice.session(live:)`), with the page's claim debounce
/// at its production defaults on a synthetic clock. Per way of leaving
/// (home, lock, another tab), the time from the page learning it left (the
/// background notification, or the page going away) to the Mac's PTY taking
/// the pane's own grid again. The mock answers in the same turn: add one
/// round trip to the Mac for the device. Coming back claims again.
@MainActor
@Suite(.serialized) struct TerminalAltScreenReleaseHarnessTests {
    typealias Debounce = TerminalSizeClaimDebounce<ContinuousClock.Instant>

    struct Leave: CustomStringConvertible {
        let name: String
        /// Leave to the Mac's own grid; nil: not within 10 min.
        let release: Duration?
        let reclaimed: Bool
        var description: String {
            "\(name): leave to release \(release.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" } ?? "none in 10 min"), reclaimed on return \(reclaimed)"
        }
    }

    static func run() -> [Leave] {
        let mac = MacPaneMockSession(columns: 120, rows: 40)
        let session = TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: "zsh")
        var claim = Debounce()
        var now = ContinuousClock.now
        func advance(_ duration: Duration) {
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
        var released: Bool { mac.ptyGrid == mac.paneGrid }
        claim.pageShown = true
        advance(.zero)
        session.resize(columns: 54, rows: 38)
        session.start { _ in }
        mac.openFullScreen()
        advance(.zero)
        var leaves: [Leave] = []
        func measure(_ name: String, leave: () -> Void, back: () -> Void) {
            precondition(!released, "the full-screen app claims the phone's grid first")
            let start = now
            leave()
            advance(.zero)
            var release: Duration? = released ? .zero : nil
            if release == nil {
                // Each recheck the debounce asks for, up to 10 min.
                let deadline = start.advanced(by: .seconds(600))
                while !released, now < deadline {
                    let next = claim.releaseAt.map { min($0, deadline) } ?? deadline
                    advance(max(.zero, now.duration(to: next)))
                }
                if released { release = start.duration(to: now) }
            }
            back()
            advance(.zero)
            leaves.append(Leave(name: name, release: release, reclaimed: !released))
        }
        measure("home", leave: { claim.appActive = false }, back: { claim.appActive = true })
        measure("lock", leave: { claim.appActive = false }, back: { claim.appActive = true })
        measure("another tab", leave: { claim.pageShown = false }, back: { claim.pageShown = true })
        return leaves
    }

    @Test func leavingReleasesTheFullScreenClaim() {
        let leaves = Self.run()
        for leave in leaves { print("alt release harness: \(leave)") }
        for leave in leaves {
            #expect(leave.release != nil, "\(leave)")
            #expect(leave.reclaimed, "\(leave)")
        }
        // Leo: "if I do completely switch away, I want to be gone": at once.
        for leave in leaves where leave.name != "another tab" {
            #expect(leave.release == .zero, "\(leave)")
        }
    }
}
