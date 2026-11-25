import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, what a clip of the other panes costs: the count of masks and animations in the frame that
/// shows a zoom key's move, and how much of a pane a clip on one edge takes that the pane that grows does not cover.
///
/// - The count is a fact of the layers, on each Mac. Under ONE pane that moves each other pane has one mask on its
///   clip, in each kind of window (`PaneCommitMotion+Under`), and no animation on its own layer or its clip's.
/// - A clip on one edge is the way under several panes that move with no ground (`PaneCommitMotion+Cover`); the math
///   is read here on a zoom's rects, the largest move of a rect. A clip that goes with one edge of the rect of the
///   pane that grows shows nothing of a pane inside that rect. For a pane in the row or the column of the pane that
///   grows it takes no more than the rect covers. A pane in another row and another column loses a corner in some
///   frames: the part beside the rect that is past that edge.
extension PaneCommitMotionTests {
    /// One zoom key's move over `panes` panes in one kind of window.
    struct Crowd: CustomTestStringConvertible, Sendable {
        let kind: String
        let scene: String
        let panes: Int
        var testDescription: String { "\(scene), \(kind), \(panes) panes" }
    }

    nonisolated static let crowds: [Crowd] = ["glass", "still", "opaque"].flatMap { kind in
        ["zoom", "unzoom"].flatMap { scene in [4, 30].map { Crowd(kind: kind, scene: scene, panes: $0) } }
    }

    /// The count of animations on `layer`, on its mask and on each layer in it.
    static func animations(in layer: CALayer) -> Int {
        (layer.animationKeys()?.count ?? 0) + (layer.mask.map { animations(in: $0) } ?? 0)
            + (layer.sublayers ?? []).reduce(0) { $0 + animations(in: $1) }
    }

    /// The animations and the clips of one frame of a move.
    struct Cost: Equatable, CustomStringConvertible {
        /// The animations on the layers of the screen's panes, and on the dim's layers.
        var all = 0, dim = 0
        /// The animations on the layers and the clips' layers of the panes other than the one that the key moves,
        /// the count of those layers that have a mask, and the animations on the layers of those masks.
        var others = 0, masks = 0, holes = 0
        var description: String {
            "\(all) animations on the panes, \(dim) on the dim, \(others) on the other panes' layers and clips, \(masks) masks there with \(holes) animations"
        }
    }

    /// The cost of the frame that `over` shows now. `others`: the panes other than the one that the key moves.
    static func cost(of over: OverPicture, others: [PaneHostView]) -> Cost {
        var cost = Cost()
        cost.all = over.screen.layer.map { animations(in: $0) } ?? 0
        let dim = Dim.dim(over.harness)?.view.layer
        cost.dim = dim.map { animations(in: $0) } ?? 0
        for host in others {
            for layer in [host.layer, host.clipView.layer].compactMap({ $0 }) {
                cost.others += layer.animationKeys()?.count ?? 0
                cost.masks += layer.mask == nil ? 0 : 1
                cost.holes += layer.mask.map { animations(in: $0) } ?? 0
            }
        }
        return cost
    }

    /// The frame that shows a zoom or an unzoom of 4 and of 30 panes, and the frame after it, in a glass window, over
    /// one still picture and in an opaque window: each pane other than the one that the key moves has one mask, on
    /// its clip's layer, with at most 8 animations on the mask's 4 parts (`PaneHoleMaskLayer`), and no animation on
    /// its own layer or on its clip's layer. The row prints the counts of each case.
    @Test(arguments: crowds)
    func aMoveOfOnePaneGivesEachOtherPaneOneMaskAndNoAnimationOfItsOwn(_ crowd: Crowd) throws {
        let over = try Self.overPicture(crowd.scene, panes: crowd.panes, gap: crowd.kind == "still" ? nil : crowd.kind, speed: .fast)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(crowd.kind, of: over)
        let movers = Self.movers(of: crowd.scene, on: over.screen)
        try #require(movers.count == 1, "SETUP: the \(crowd.scene) moves \(movers.count) panes over the others, not 1")
        let others = Self.paneHosts(over.screen).filter { host in !host.isHidden && !movers.contains { $0 === host } }
        try #require(!others.isEmpty, "SETUP: the frame that shows the \(crowd.scene) shows no other pane")
        let moved = over.screen.zoomDim.motion.moved.count
        let first = Self.cost(of: over, others: others)
        _ = over.harness.root.advanceFrame(Self.dt)
        let second = Self.cost(of: over, others: others)
        print("COUNT ROW: \(crowd.testDescription): \(others.count) other panes show; the motion holds \(moved) animations;",
              "the frame that shows the act: \(first); the frame after it: \(second)")
        let masked = others.filter { $0.layer?.mask == nil && $0.clipView.layer?.mask != nil }.count
        #expect(masked == others.count, "\(masked) of the \(others.count) other panes have a mask on their clip and none on their own layer")
        for (frame, cost) in [("that shows the \(crowd.scene)", first), ("after the one that shows the \(crowd.scene)", second)] {
            #expect(cost.masks == others.count && cost.others == 0 && cost.holes <= 8 * others.count,
                    "the frame \(frame), \(others.count) other panes: \(cost)")
        }
    }

    /// One edge of the rect of the pane that grows, as the clip of a pane on that side of it.
    enum Edge {
        case left, right, above, below

        /// What a clip on this edge of `rect` shows of `pane`: the part of the pane past the edge.
        func shows(of pane: CGRect, beside rect: CGRect) -> CGRect {
            switch self {
            case .left: return pane.intersection(CGRect(x: pane.minX, y: pane.minY, width: max(0, rect.minX - pane.minX), height: pane.height))
            case .right: return pane.intersection(CGRect(x: rect.maxX, y: pane.minY, width: max(0, pane.maxX - rect.maxX), height: pane.height))
            case .above: return pane.intersection(CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: max(0, rect.minY - pane.minY)))
            case .below: return pane.intersection(CGRect(x: pane.minX, y: rect.maxY, width: pane.width, height: max(0, pane.maxY - rect.maxY)))
            }
        }
    }

    /// The diagonal's cost, by the math of the move: a grid of 6 by 5 panes in the test window's size, and a zoom of
    /// the pane in a corner and of a pane in the middle, read at each frame of the zoom's spring. Each other pane has
    /// a clip on one edge of the rect of the pane that grows: an edge on the pane's own side of that pane, and for a
    /// pane with 2 such edges the one that takes less of it at the worst frame. The clip shows no part of a pane
    /// inside the rect, in no frame. A pane in the row or the column of the pane that grows loses nothing more. The
    /// row prints how many panes lose a corner, in how many frames, and the largest part that one pane loses.
    @Test(arguments: movingSpeeds)
    func aClipOnOneEdgeShowsNoPaneInsideThePaneThatGrows(_ speed: MotionSpeed) {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000), columns = 6, rows = 5
        let width = screen.width / CGFloat(columns), height = screen.height / CGFloat(rows)
        func cell(_ column: Int, _ row: Int) -> CGRect { CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height) }
        let frames = Int((Self.zoomKey(.zoom, at: speed).end / Self.dt).rounded(.up))
        let ways = (0...frames).map { Self.way(of: "zoom", at: speed, tick: $0) }
        for start in [(column: 0, row: 0), (column: 2, row: 2)] {
            let from = cell(start.column, start.row)
            let rects = ways.map { way in
                CGRect(x: from.minX * (1 - way), y: from.minY * (1 - way),
                       width: from.width + (screen.width - from.width) * way, height: from.height + (screen.height - from.height) * way)
            }
            var inside: CGFloat = 0, straight: CGFloat = 0, largest: CGFloat = 0, panes = 0, reads = 0, mostFrames = 0
            for column in 0..<columns {
                for row in 0..<rows where column != start.column || row != start.row {
                    let pane = cell(column, row)
                    var edges: [Edge] = []
                    if column < start.column { edges.append(.left) }
                    if column > start.column { edges.append(.right) }
                    if row < start.row { edges.append(.above) }
                    if row > start.row { edges.append(.below) }
                    var best: (worst: CGFloat, frames: Int)?
                    for edge in edges {
                        var worst: CGFloat = 0, lostFrames = 0
                        for rect in rects {
                            let shows = edge.shows(of: pane, beside: rect)
                            inside = max(inside, Self.area(shows.intersection(rect)))
                            let lost = Self.area(pane) - Self.area(pane.intersection(rect)) - Self.area(shows)
                            worst = max(worst, lost)
                            if lost >= 1 { lostFrames += 1 }
                        }
                        if best.map({ worst < $0.worst }) ?? true { best = (worst: worst, frames: lostFrames) }
                    }
                    guard let best else { continue }
                    if edges.count == 1 { straight = max(straight, best.worst) }
                    guard best.worst >= 1 else { continue }
                    panes += 1
                    reads += best.frames
                    mostFrames = max(mostFrames, best.frames)
                    largest = max(largest, best.worst)
                }
            }
            let name = "a zoom from column \(start.column), row \(start.row) of 6 by 5 panes at `\(speed.rawValue)` (\(frames) frames)"
            print("DIAGONAL ROW: \(name): \(panes) panes lose a corner, in \(reads) reads of a pane in a frame, at most \(mostFrames) frames",
                  "for one pane; the largest part is \(Int(largest)) pt2 of a pane of \(Int(width * height)) pt2")
            #expect(inside < 1, "\(name): a clip on one edge shows \(inside) pt2 of a pane inside the pane that grows")
            #expect(straight < 1, "\(name): a pane in the row or the column of the pane that grows loses \(straight) pt2 that the rect does not cover")
            #expect(panes <= (columns - 1) * (rows - 1), "\(name): \(panes) panes lose a corner; \((columns - 1) * (rows - 1)) panes are in another row and another column")
        }
    }

    /// The side that the product code takes for each pane of the same grid (`PaneCommitMotion.coverSide`), read at
    /// each frame of the zoom's spring: a window on that side shows nothing of the pane inside the rect of the pane
    /// that grows; a pane in the row or the column of that pane loses nothing that the rect does not cover; and the
    /// move back takes the same side, so a move and the move back in it give one window.
    @Test(arguments: movingSpeeds)
    func theSideOfAPanesWindowTakesNothingInTheRowAndTheColumnOfThePaneThatGrows(_ speed: MotionSpeed) {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000), columns = 6, rows = 5
        let width = screen.width / CGFloat(columns), height = screen.height / CGFloat(rows)
        func cell(_ column: Int, _ row: Int) -> CGRect { CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height) }
        let frames = Int((Self.zoomKey(.zoom, at: speed).end / Self.dt).rounded(.up))
        let ways = (0...frames).map { Self.way(of: "zoom", at: speed, tick: $0) }
        for start in [(column: 0, row: 0), (column: 2, row: 2)] {
            let from = cell(start.column, start.row)
            let rects = ways.map { way in
                CGRect(x: from.minX * (1 - way), y: from.minY * (1 - way),
                       width: from.width + (screen.width - from.width) * way, height: from.height + (screen.height - from.height) * way)
            }
            var inside: CGFloat = 0, straight: CGFloat = 0, turned = 0
            for column in 0..<columns {
                for row in 0..<rows where column != start.column || row != start.row {
                    let pane = cell(column, row)
                    let side = PaneCommitMotion.coverSide(of: pane, under: from, to: screen)
                    if PaneCommitMotion.coverSide(of: pane, under: screen, to: from) != side { turned += 1 }
                    for rect in rects {
                        inside = max(inside, Self.area(side.shows(of: pane, past: rect).intersection(rect)))
                        guard column == start.column || row == start.row else { continue }
                        straight = max(straight, PaneCommitMotion.lost(of: pane, past: side, of: rect))
                    }
                }
            }
            let name = "a zoom from column \(start.column), row \(start.row) of 6 by 5 panes at `\(speed.rawValue)`"
            #expect(inside < 1, "\(name): a window on the product's side shows \(inside) pt2 of a pane inside the pane that grows")
            #expect(straight < 1, "\(name): a pane in the row or the column of the pane that grows loses \(straight) pt2 that the rect does not cover")
            #expect(turned == 0, "\(name): for \(turned) panes the move back takes another side than the move")
        }
    }
}
