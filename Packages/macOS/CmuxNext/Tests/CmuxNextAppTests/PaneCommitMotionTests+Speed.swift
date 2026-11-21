import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the motion at the `normal` speed, with a padding around each pane's content and a
/// header in it.
///
/// The speed is a setting of the whole app: each other row of this suite runs at the `fast` speed, with no padding
/// and with a content that has no header. This row gives the motion its speed as an input
/// (`PaneCommitMotion.speed`), so it changes no setting beside the rows that run at the same time.
extension PaneCommitMotionTests {
    /// The acts of the row, each with the response of its spring at the `normal` speed in seconds. The rule of the
    /// design's policy (`MotionPolicy.spring`): 1.5 times the response at `fast`, and at most 0.25 s. At `fast` a
    /// split has 0.085 s, a close 0.064 s, a zoom 0.095 s and an unzoom 0.08 s.
    nonisolated static let normalScenes = ["split, held", "close", "zoom", "unzoom"]
    nonisolated static let normalResponses = ["split, held": 0.1275, "close": 0.096, "zoom": 0.1425, "unzoom": 0.12]

    /// A split, a close, a zoom and an unzoom of 6 panes over a window's picture, at the `normal` speed, with a
    /// padding of 2 pt around each pane's content and a header of 28 pt in it. Each move of a pane is a spring with
    /// the act's response at that speed, and each move has one length. Each pane that moves has 1 copy of the
    /// window's picture, and at the start, at each quarter and at the end of the move the copy shows the picture
    /// where the window has it. The motion ends by the frame clock where the spring's animation ends.
    @Test(arguments: normalScenes)
    func atTheNormalSpeedWithAPaddingAndAHeaderEachActHasItsTimeAndEachCopyItsPlace(_ scene: String) throws {
        let over = try Self.overPicture(scene, panes: 6, speed: .normal, padding: 2)
        defer { over.harness.window.closeAfterTest() }
        let screen = over.screen, art = over.backdrop.artView
        let want = art.convert(art.bounds, to: nil)
        let response = try #require(Self.normalResponses[scene], "SETUP: no response for the \(scene)")
        let movers = Self.paneHosts(screen).filter { Self.moves($0) }
        let first = try #require(movers.first, "SETUP: no pane moves at the \(scene)")
        try #require(first.headerHeight == 28 && abs(first.contentRect.minX - 2) < 0.01 && !first.wholeCard,
                     "SETUP: the pane has a header of \(first.headerHeight) pt and its clip at \(first.contentRect), not a header of 28 pt and a padding of 2 pt")
        var lengths: Set<Double> = []
        for host in movers {
            guard let layer = host.layer else { continue }
            let copies = Self.pictures(on: host)
            #expect(copies.count == 1, "at the \(scene) the pane \(host.pane) moves with \(copies.count) copies of the window's picture under it")
            for animation in Self.move(of: layer).animations + (copies.first.map { Self.move(of: $0).animations } ?? []) {
                let spring = animation as? CASpringAnimation
                let has = spring.map { 2 * Double.pi / Double($0.stiffness / $0.mass).squareRoot() } ?? 0
                #expect(abs(has - response) < 0.0005,
                        "a move of \(host.pane) at the \(scene) is a spring with the response \(has) s; at the normal speed the act's response is \(response) s")
                lengths.insert((animation.duration * 10000).rounded() / 10000)
            }
            guard let copy = copies.first else { continue }
            for part in Self.quarters {
                let shows = Self.windowRect(of: copy, on: host, in: screen, at: { _ in part }) ?? .zero
                #expect(Commit.near(shows, want),
                        "at \(part) of the \(scene)'s move the copy under \(host.pane) shows the picture at \(shows) in the window; the window has it at \(want)")
            }
        }
        let length = try #require(lengths.first, "SETUP: no move of a pane is an animation")
        #expect(lengths.count == 1 && length > response && length < 1.5 * response,
                "the moves of the \(scene) have the lengths \(lengths.sorted()) s; one length is wanted, between the response \(response) s and 1.5 times it")
        var ticks = 0
        while Self.inFlight(screen), ticks < 120 {
            _ = over.harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        let spent = Double(ticks) * Self.dt
        #expect(abs(spent - length) <= 2 * Self.dt, "the motion ended \(spent) s after the frame that began it; its springs end at \(length) s")
    }
}
