import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a search and not a row for the product: NEVER MERGE.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A second close in a close's move
/// keeps the closed pane under the panes that take its room, and the motion ends that pane's own move in that pass.
/// The search reads 2 closes in each kind of window that gives a pane no ground, at the 2 speeds at which a pane
/// moves, with 5 counts of panes, 3 times of the second key and 2 picks of the pane that closes second. It prints, for
/// each case, the count of reads in which another pane shows inside a pane that grows.
extension PaneCommitMotionTests {
    /// The kinds of window with no ground, each at each speed.
    nonisolated static let twoClosesLooks: [Look] = ["glass", "blur", "seeThrough", "noPicture"].flatMap { kind in
        movingSpeeds.map { Look(kind: kind, scene: "close", speed: $0) }
    }

    /// One number for each shape of a case: 100 for each pane, 10 for each frame between the frame that shows the first
    /// close and the second key, and 1 when the pane that closes second is the last by name of the panes that grew.
    /// The counts of panes are 3, 4, 5, 7 and 9; the times are 1, 3 and 6 frames.
    nonisolated static let twoClosesShapes: [Int] = [
        310, 311, 330, 331, 360, 361, 410, 411, 430, 431, 460, 461, 510, 511, 530, 531, 560, 561,
        710, 711, 730, 731, 760, 761, 910, 911, 930, 931, 960, 961,
    ]

    @Test(arguments: twoClosesLooks, twoClosesShapes)
    func searchASecondCloseThatShowsAnotherPaneInsideAPaneThatGrows(_ look: Look, _ shape: Int) throws {
        let panes = shape / 100, wait = (shape / 10) % 10, last = shape % 10 == 1, speed = look.speed
        let name = "SEARCH (2 CLOSES): \(look.kind), \(speed.rawValue), \(panes) panes, key after \(wait) frames, the \(last ? "last" : "first") pane that grew"
        let over = try Self.overPicture("close", panes: panes, gap: look.gap, speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let grown = Self.movers(of: "close", on: screen).sorted { "\($0.pane)" < "\($1.pane)" }
        guard let second = last ? grown.last : grown.first else {
            print("\(name): NO CASE, the first close makes no pane grow")
            return
        }
        for _ in 0..<wait { _ = harness.root.advanceFrame(Self.dt) }
        guard Self.inFlight(screen) else {
            print("\(name): NO CASE, no pane moves at the second key")
            return
        }
        let first = motion.serial
        guard harness.model.showPaneClose(second.pane) != nil else {
            print("\(name): NO CASE, the model does not show the close of \(second.pane)")
            return
        }
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        guard motion.serial == first + 1 else {
            print("\(name): NO CASE, the close of \(second.pane) shows in one frame")
            return
        }
        let kept = second.isLeaving && !second.isHidden
        let left = Self.paneHosts(screen).filter { $0.isLeaving && !$0.isHidden }
        let grows = Self.movers(of: "close", on: screen)
        guard !grows.isEmpty else {
            print("\(name): NO CASE, the close of \(second.pane) makes no pane grow")
            return
        }
        let grounded = grows.filter { Self.hasFullGround($0) }.count
        let others = Self.paneHosts(screen).filter { host in !grows.contains { $0 === host } }
        var faults: [String] = [], under = 0, tick = 0, most: CGFloat = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let part: (Int) -> CGFloat = { act in
                Self.way(of: "close", at: speed, tick: act == first ? wait + 1 + now : now)
            }
            for pane in grows {
                guard let layer = pane.layer else { continue }
                let rect = Self.rect(of: layer, at: part)
                var shows: [String] = []
                for other in others {
                    if !other.isHidden, Self.area(other.frame.intersection(rect)) >= 1 { under += 1 }
                    let inside = Self.showing(other, on: screen, at: part).reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if inside >= 1 {
                        shows.append("\(other.pane) in \(Int(inside)) pt2")
                        most = max(most, inside)
                    }
                }
                if !shows.isEmpty { faults.append("tick \(tick), inside \(pane.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        print("\(name): the pane \(second.pane), kept under: \(kept); panes that left and show: \(left.count); panes that grow: \(grows.count),",
              "with a ground: \(grounded); frames read: \(tick); reads of a place under a pane that grows: \(under);",
              "RULE FAULTS: \(faults.count), the most \(Int(most)) pt2; the first: \(faults.prefix(2))")
        #expect(faults.isEmpty, "\(name): \(faults.count) reads show another pane inside a pane that grows; the first: \(faults.prefix(3))")
    }
}
