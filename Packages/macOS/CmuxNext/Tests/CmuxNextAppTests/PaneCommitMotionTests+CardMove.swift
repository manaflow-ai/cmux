import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the card of a pane that moves.
///
/// In a chrome style with a card for each pane a pane's clip is its card: the pane's cell less the padding, with
/// round corners. The card goes with its pane: in each frame of a move the clip is the pane's cell at that frame
/// less the padding. So the card keeps its inset and its corners while it moves, and what the motion puts under or
/// beside the pane's content is in the clip. A frame of a move is a calculation from the animations on the layers
/// (`rect(of:at:)`): the window of a test has no presentation layer.
extension PaneCommitMotionTests {
    /// The acts of a row in a style with a card for each pane (``overPicture(_:panes:gap:speed:padding:cards:prepare:)``).
    nonisolated static let cardScenes = ["close", "split", "split, held", "zoom", "unzoom"]
    /// The padding of that style.
    nonisolated static let cardPadding: CGFloat = 6

    /// Where the clip of `host` is in its host when the moves of each act are at `part(act)` of their way: the
    /// clip's frame, with the moves on its layer.
    static func cardRect(of host: PaneHostView, at part: (Int) -> CGFloat) -> CGRect {
        let frame = host.clipView.frame
        guard let layer = host.clipView.layer else { return frame }
        let now = rect(of: layer, at: part), end = rect(of: layer, at: { _ in 1 })
        return CGRect(x: frame.minX + now.minX - end.minX, y: frame.minY + now.minY - end.minY,
                      width: frame.width + now.width - end.width, height: frame.height + now.height - end.height)
    }

    /// The cell of `host` in its own coordinates at `part`.
    static func cell(of host: PaneHostView, at part: (Int) -> CGFloat) -> CGRect {
        guard let layer = host.layer else { return host.bounds }
        return CGRect(origin: origin(of: layer, at: part), size: rect(of: layer, at: part).size)
    }

    /// What shows of the card of `host` in the window at `part`: its clip, cut by its cell.
    static func cardInWindow(of host: PaneHostView, on screen: ScreenContentView, at part: (Int) -> CGFloat) -> CGRect {
        guard let layer = host.layer else { return .zero }
        let own = cell(of: host, at: part), shown = rect(of: layer, at: part)
        let card = cardRect(of: host, at: part).intersection(own)
        guard !card.isNull else { return .zero }
        return screen.convert(card.offsetBy(dx: shown.minX - own.minX, dy: shown.minY - own.minY), to: nil)
    }

    /// The layers with `name` in `layer`.
    static func layers(named name: String, in layer: CALayer?) -> [CALayer] {
        (layer?.sublayers ?? []).filter { $0.name == name }
    }

    /// A close, a split, a split with a held content, a zoom and an unzoom of 2 and of 6 panes over a window's
    /// picture, in a style with a card for each pane. At the start, at each quarter and at the end of the move the
    /// clip of each pane that moves is the pane's cell at that frame less the padding. A pane that comes starts
    /// with no room: its clip is inside its cell in each frame, and it is the cell less the padding at the start
    /// and at the end. The clip has at most one move of each kind for the act: a held content and the card are 2
    /// reasons for the same move, and they do not add. The copy of the window's picture is in the clip, it shows
    /// the picture where the window has it in each of those frames, and it covers the card.
    @Test(arguments: cardScenes, [2, 6])
    func inACardStyleAPanesClipIsItsCardInEachFrameOfTheMove(_ scene: String, _ count: Int) throws {
        let over = try Self.overPicture(scene, panes: count, padding: Self.cardPadding, cards: true)
        defer { over.harness.window.closeAfterTest() }
        let screen = over.screen, art = over.backdrop.artView
        let picture = art.convert(art.bounds, to: nil)
        let movers = Self.paneHosts(screen).filter { Self.moves($0) }
        try #require(!movers.isEmpty && movers.allSatisfy(\.wholeCard), "SETUP: a pane that moves at the \(scene) has no card")
        let held = screen.zoomDim.motion.holds.count
        try #require((held > 0) == (scene == "split, held"), "SETUP: \(held) contents hold their picture at the \(scene)")
        var came = 0
        for host in movers {
            guard let layer = host.layer, let clip = host.clipView.layer else { continue }
            let start = Self.move(of: layer).start
            let comes = start.width < 0.5 || start.height < 0.5
            if comes { came += 1 }
            let paths = Self.move(of: clip).animations.compactMap(\.keyPath)
            #expect(Set(paths).count == paths.count, "at the \(scene) the clip of \(host.pane) has 2 moves of one kind for one act: \(paths)")
            let copies = Self.layers(named: Self.pictureCopy, in: clip)
            #expect(copies.count == 1 && Self.pictures(on: host).isEmpty,
                    "at the \(scene) the pane \(host.pane) has \(copies.count) copies in its clip and \(Self.pictures(on: host).count) on its cell")
            for part in Self.quarters {
                let at: (Int) -> CGFloat = { _ in part }
                let cell = Self.cell(of: host, at: at), card = Self.cardRect(of: host, at: at)
                let want = cell.insetBy(dx: min(Self.cardPadding, cell.width / 2), dy: min(Self.cardPadding, cell.height / 2))
                if comes, part > 0, part < 1 {
                    #expect(cell.insetBy(dx: -0.51, dy: -0.51).contains(card),
                            "at \(part) of the \(scene)'s move the clip of the pane \(host.pane) that comes is \(card): not inside its cell \(cell)")
                } else {
                    #expect(Commit.near(card, want),
                            "at \(part) of the \(scene)'s move the clip of \(host.pane) is \(card); its cell \(cell) less the padding is \(want)")
                }
                guard let copy = copies.first else { continue }
                let shows = Self.windowRect(of: copy, on: host, in: screen, at: at) ?? .zero
                #expect(Commit.near(shows, picture),
                        "at \(part) of the \(scene)'s move the copy in the clip of \(host.pane) shows the picture at \(shows); the window has it at \(picture)")
                let shown = Self.cardInWindow(of: host, on: screen, at: at)
                #expect(shows.insetBy(dx: -0.51, dy: -0.51).contains(shown),
                        "at \(part) of the \(scene)'s move the copy at \(shows) does not cover the card \(shown) of \(host.pane)")
            }
        }
        let wanted = scene.hasPrefix("split") ? 1 : 0
        #expect(came == wanted, "SETUP: \(came) panes come at the \(scene), not \(wanted)")
    }

    /// With no card for each pane the clip of a pane whose content holds no picture has no move: the pane's cell
    /// cuts its content. The ground strips beside a pane that gets smaller are on the cell, and an unzoom's last
    /// frame is a view of the pane's host.
    @Test(arguments: ["close", "split", "zoom", "unzoom"])
    func withNoCardAPanesClipHasNoMoveOfItsOwn(_ scene: String) throws {
        let own = CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let over = try Self.overPicture(scene, panes: 6, padding: Self.cardPadding) { harness in
            for content in harness.provider.contents.values { content.layer?.backgroundColor = own }
        }
        defer { over.harness.window.closeAfterTest() }
        let movers = Self.paneHosts(over.screen).filter { Self.moves($0) }
        try #require(!movers.isEmpty && !movers.contains(where: \.wholeCard), "SETUP: a pane that moves at the \(scene) has a card")
        for host in movers {
            let clip = try #require(host.clipView.layer, "SETUP: the pane's clip has no layer")
            let paths = Self.move(of: clip).animations.compactMap(\.keyPath)
            #expect(paths.isEmpty, "with no card the clip of \(host.pane) has the moves \(paths) at the \(scene)")
            let inClip = Self.layers(named: Self.groundStrip, in: clip).count + Self.layers(named: PaneCommitMotion.lastFrameName, in: clip).count
            #expect(inClip == 0, "with no card the clip of \(host.pane) has \(inClip) layers of the motion beside its ground at the \(scene)")
        }
        if scene == "split" {
            let strips = movers.reduce(0) { $0 + Self.layers(named: Self.groundStrip, in: $1.layer).count }
            #expect(strips > 0, "with no card no pane that gets smaller at the split has a ground strip on its cell")
        }
        if scene == "unzoom" {
            let views = movers.reduce(0) { sum, host in sum + host.subviews.filter { $0.identifier?.rawValue == PaneCommitMotion.lastFrameName }.count }
            #expect(views == 1, "with no card the pane of the unzoom has \(views) last frames on its host")
        }
    }

    /// A split's old pane gets smaller, and its content has its own ground colour and its final size from the first
    /// frame. In a style with a card for each pane the strips of that colour beside the content are in the pane's
    /// clip, not on its cell: the card cuts them with its corners, and they cover nothing of the gaps. With the
    /// content they cover the card that the pane had. The motion's end takes them away.
    @Test func inACardStyleTheGroundBesideAPaneThatGetsSmallerIsInItsCard() throws {
        let own = CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let over = try Self.overPicture("split", panes: 2, padding: Self.cardPadding, cards: true) { harness in
            for content in harness.provider.contents.values { content.layer?.backgroundColor = own }
        }
        defer { over.harness.window.closeAfterTest() }
        let smaller = Self.paneHosts(over.screen).first { host in
            guard Self.moves(host), let layer = host.layer else { return false }
            let move = Self.move(of: layer)
            return move.start.width > move.end.width + 0.5 || move.start.height > move.end.height + 0.5
        }
        let host = try #require(smaller, "SETUP: no pane gets smaller at the split")
        try #require(host.wholeCard && host.content.paneGroundColor == own, "SETUP: the pane has no card, or its content does not report its ground")
        let clip = try #require(host.clipView.layer, "SETUP: the pane's clip has no layer")
        let onCell = Self.layers(named: Self.groundStrip, in: host.layer), inCard = Self.layers(named: Self.groundStrip, in: clip)
        #expect(onCell.isEmpty && !inCard.isEmpty, "the pane that gets smaller has \(onCell.count) ground strips on its cell and \(inCard.count) in its clip")
        #expect(inCard.allSatisfy { $0.backgroundColor == own }, "a ground strip in the clip is not of the pane's own colour")
        let content = CGRect(origin: .zero, size: host.clipView.frame.size)
        let had = Self.cardRect(of: host, at: { _ in 0 }).size
        let open = Self.uncovered(inCard.map(\.frame) + [content], in: CGRect(origin: .zero, size: had))
        #expect(had.width > content.width + 0.5 || had.height > content.height + 0.5, "the clip of the pane that gets smaller starts at \(had): not larger than its end \(content.size)")
        #expect(open < 1, "\(open) pt2 of the card \(had) that the pane had shows no ground of its own beside the content")
        _ = Self.toTheEnd(over.harness, over.screen)
        let left = Self.layers(named: Self.groundStrip, in: host.layer).count + Self.layers(named: Self.groundStrip, in: clip).count
        #expect(left == 0, "after the motion's end the pane keeps \(left) ground strips")
    }

    /// An unzoom shows its pane's last frame at its old size over the pane's content. In a style with a card for
    /// each pane the last frame is a layer of the pane's clip, over each other layer of it, where the content
    /// showed: the card cuts it as it moves. The pane's host has no view for it. The motion's end takes it away.
    @Test func inACardStyleAnUnzoomsLastFrameIsInThePanesCard() throws {
        let over = try Self.overPicture("unzoom", panes: 6, padding: Self.cardPadding, cards: true)
        defer { over.harness.window.closeAfterTest() }
        let host = try #require(Self.paneHosts(over.screen).first { Self.moves($0) }, "SETUP: no pane moves at the unzoom")
        try #require(host.wholeCard, "SETUP: the pane of the unzoom has no card")
        let clip = try #require(host.clipView.layer, "SETUP: the pane's clip has no layer")
        let name = PaneCommitMotion.lastFrameName
        func views() -> Int { host.subviews.filter { $0.identifier?.rawValue == name }.count }
        let inCard = Self.layers(named: name, in: clip)
        #expect(views() == 0 && inCard.count == 1, "the pane of the unzoom has \(views()) last frames on its host and \(inCard.count) in its clip")
        if let last = inCard.first {
            let had = Self.cardRect(of: host, at: { _ in 0 }).size
            #expect(Commit.near(last.frame, CGRect(origin: .zero, size: had)) && last.zPosition > 0 && last.contents != nil,
                    "the last frame is at \(last.frame) with the zPosition \(last.zPosition); the card that the pane had is \(had)")
        }
        _ = Self.toTheEnd(over.harness, over.screen)
        let left = views() + Self.layers(named: name, in: clip).count
        #expect(left == 0, "after the motion's end the pane keeps \(left) last frames")
    }

    /// The ground of a pane that moves is under a layer that the pane had before the act. A row of this suite has
    /// a window with no display, so the layers of a view's subviews are not in the view's layer: this row puts one
    /// layer there itself. With a card the ground is the first layer of the pane's clip, else the copy is the first
    /// layer of the pane's cell; the other layer stays over it.
    @Test(arguments: zip([true, true, false], [true, false, true]))
    func theGroundIsUnderALayerThatThePaneHadBeforeTheAct(_ cards: Bool, _ picture: Bool) throws {
        let marker = CALayer()
        let scene = try Self.closeInStyle(cards: cards, picture: picture, marker: marker)
        defer { scene.harness.window.closeAfterTest() }
        let home = cards ? scene.host.clipView.layer : scene.host.layer
        let layers = home?.sublayers ?? []
        let found = cards ? Self.grounds(inCardOf: scene.host).first : Self.pictures(on: scene.host).first
        let ground = try #require(found, "the pane that moves has no ground layer")
        let lowest: Bool = layers.first === ground
        let kept: Bool = layers.contains { $0 === marker }
        #expect(lowest && kept && layers.count > 1 && ground.zPosition < marker.zPosition,
                "the ground is the first of the \(layers.count) layers: \(lowest); the layer that the pane had is there: \(kept); the ground's zPosition is \(ground.zPosition)")
    }

    /// KNOWN, NOT MENDED: the hole that the layout gives to the gaps' shade for a pane is the pane's card at the
    /// END of a move, from the first frame of the move. A card that moves is not at that place yet, so a part of
    /// the hole has no card over it: the gap between 2 cards shows the window with no shade there for the move's
    /// time. This row reads a close of 1 of 2 panes over a picture at the start, at each quarter and at the end:
    /// no hole may have a part with no card. It is red until the hole goes with its card.
    @Test func inACardStyleTheGapsShadeHasNoHoleWhereNoCardIs() throws {
        let over = try Self.overPicture("close", panes: 2, padding: Self.cardPadding, cards: true)
        defer { over.harness.window.closeAfterTest() }
        let screen = over.screen
        let holes = over.harness.root.paneCardsInWindow.map { $0.rect }
        try #require(!holes.isEmpty, "SETUP: the layout gives the gaps' shade no hole")
        let shown = Array(Self.hosts(of: screen).values)
        withKnownIssue("the hole of the gaps' shade is its pane's end card from the first frame of a move: it does not go with the card") {
            for part in Self.quarters {
                let cards = shown.map { Self.cardInWindow(of: $0, on: screen, at: { _ in part }) }
                var bare: CGFloat = 0
                for hole in holes {
                    bare += Self.area(of: hole, cutBy: cards) { point in !cards.contains { $0.contains(point) } }
                }
                #expect(bare < 1, "at \(part) of the close's move \(bare) pt2 of the holes \(holes) have no card over them: \(cards)")
            }
        }
    }

    /// The acts of the cost row: the close key on the first pane, a close of the first half of the panes (the
    /// second half takes the whole screen: the most panes that one close moves), and a zoom.
    nonisolated static let cardCostScenes = ["close", "close, half", "zoom"]

    /// What a card that goes with its pane costs, at 30 panes over a window's picture in a style with a card for
    /// each pane. The row prints, for one act: the panes that move, the animations of the motion on the cells, on
    /// the clips and on the grounds in the clips, and the clips that cut with a round corner at a size that
    /// changes. Each pane whose size changes has 1 such clip, and a clip has at most 2 animations (its size, and
    /// its place for a pane that comes). The time of a frame is not read here.
    @Test(arguments: cardCostScenes)
    func inACardStyleAt30PanesEachPaneWhoseSizeChangesHasOneRoundCutThatMoves(_ scene: String) throws {
        let over = try Self.overPicture(scene, panes: 30, padding: Self.cardPadding, cards: true)
        defer { over.harness.window.closeAfterTest() }
        let all = Self.paneHosts(over.screen), movers = all.filter { Self.moves($0) }
        try #require(!movers.isEmpty && movers.allSatisfy(\.wholeCard), "SETUP: no pane with a card moves at the \(scene)")
        func count(_ layer: CALayer?) -> Int { (layer?.animationKeys() ?? []).filter { Self.act(of: $0) != nil }.count }
        let sized = movers.filter { host in
            guard let layer = host.layer else { return false }
            let move = Self.move(of: layer)
            return abs(move.start.width - move.end.width) > 0.5 || abs(move.start.height - move.end.height) > 0.5
        }
        var onCells = 0, onClips = 0, onGrounds = 0, cuts = 0, most = 0
        for host in all {
            let clip = host.clipView.layer
            onCells += count(host.layer)
            onClips += count(clip)
            most = max(most, count(clip))
            for ground in Self.grounds(inCardOf: host) { onGrounds += count(ground) }
            guard let clip, clip.masksToBounds, clip.cornerRadius > 0 else { continue }
            if Self.move(of: clip).animations.contains(where: { $0.keyPath?.hasPrefix("bounds") ?? false }) { cuts += 1 }
        }
        print("CARD COST: \(scene) at 30 panes with a card for each pane: \(movers.count) panes move, \(sized.count) change their size; "
            + "animations of the motion: \(onCells) on the cells, \(onClips) on the clips, \(onGrounds) on the grounds in the clips; "
            + "\(cuts) clips cut with a round corner at a size that changes")
        #expect(cuts == sized.count && most <= 2,
                "at the \(scene) \(sized.count) panes change their size and \(cuts) clips move with a round corner; a clip has at most \(most) animations")
    }
}
