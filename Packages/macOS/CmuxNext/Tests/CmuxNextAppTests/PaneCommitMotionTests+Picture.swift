import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the window's picture under a pane that moves.
///
/// A window with a picture background is not opaque, and it shows one still picture of the app's own under its
/// panes, with one tint over it (`WindowMaterialView.stillPicture`). A pane's tab row and the padding around its
/// content have no ground, so the picture shows there at rest. A pane that moves in such a window has a copy of the
/// picture's layer under its content, with the tint over it. The pane's layer clips the copy, and the copy moves
/// against the pane, so it stays where the window has the picture: the pane shows what it shows at rest, and
/// nothing of a pane under it. A window whose backdrop is no still picture gives a pane no ground.
extension PaneCommitMotionTests {
    /// The name of the layer that shows the window's picture under a pane that moves.
    static let pictureCopy = "pane.commit.picture"

    /// The pane hosts of `screen`, shown or not.
    static func paneHosts(_ screen: ScreenContentView) -> [PaneHostView] { screen.subviews.compactMap { $0 as? PaneHostView } }

    /// The copies of the window's picture on the layer of `host`.
    static func pictures(on host: PaneHostView) -> [CALayer] {
        (host.layer?.sublayers ?? []).filter { $0.name == pictureCopy }
    }

    /// Whether `host` shows and has a move on its layer.
    static func moves(_ host: PaneHostView) -> Bool {
        guard !host.isHidden, let layer = host.layer else { return false }
        return move(of: layer).moves
    }

    /// Puts a picture background under the panes of the window of `harness`, as the app's window has it: the window
    /// is not opaque, and a backdrop view is the lowest view of the window's content, with a picture and a tint of
    /// 0.6 over it. `gap`: the backdrop is no still picture, for this reason (a case of `WindowPictureGap`), or the
    /// window is `opaque`: it stays opaque with its own colour, and its backdrop has no picture.
    static func picture(under harness: Commit.Harness, gap: String? = nil) -> WindowMaterialView {
        if gap != "opaque" {
            harness.window.isOpaque = false
            harness.window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        }
        let backdrop = WindowMaterialView(frame: harness.root.bounds, images: BackdropImageStore(maxPixelSize: 256), videos: BackdropVideoPlayers())
        backdrop.autoresizingMask = [.width, .height]
        harness.root.addSubview(backdrop, positioned: .below, relativeTo: nil)
        var look = WindowBackdrop(backgroundOpacity: gap == "opaque" ? 1 : 0.6, backgroundBlur: 0)
        if gap == "glass" { look = WindowBackdrop(backgroundOpacity: 0.6, backgroundBlur: -1, liquidGlass: true) }
        if gap == "blur" { look.artBlurRadius = 8 }
        if gap == "seeThrough" { look.artOpacity = 0.5 }
        backdrop.apply(look, tint: .black)
        if !["noPicture", "glass", "opaque"].contains(gap ?? "") { backdrop.showArt(NSImage(size: NSSize(width: 320, height: 200))) }
        if gap == "changing" {
            let blend = CABasicAnimation(keyPath: "backgroundColor")
            blend.duration = 600
            backdrop.shownTintLayer?.add(blend, forKey: "test.blend")
        }
        return backdrop
    }

    /// One act over a window's picture, with the frame that shows it stepped.
    struct OverPicture {
        let harness: Commit.Harness
        let screen: ScreenContentView
        let backdrop: WindowMaterialView
    }

    /// The window shows another picture from now: a copy of the one before, under a pane that moves, is not the
    /// window's picture any more.
    static func showAnotherPicture(_ over: OverPicture) {
        over.backdrop.showArt(NSImage(size: NSSize(width: 320, height: 200)))
    }

    /// The acts of a row over a picture.
    /// - `close`: the close key on the first pane; the pane beside it takes its room.
    /// - `zoom`, `unzoom`: of the pane at the far corner, so its origin moves.
    /// - `split, held`: one pane more; each pane that gets smaller keeps its own old picture (a hold).
    /// - `second close`: a second close key 3 frames into the first one's move.
    /// - `resize`: the first pane closes, and 1 frame into that move a divider's ratio changes (``resized(_:to:)``):
    ///   passes with no act place the panes again while they move.
    nonisolated static let pictureScenes = ["close", "zoom", "unzoom", "split, held", "second close", "resize"]
    nonisolated static let pictureCounts = [2, 6, 30]

    /// `node` with its first pane out: the other half of that pane's split has the split's place.
    static func withoutFirst(_ node: SplitNode) -> SplitNode {
        guard case let .split(id, axis, ratio, a, b) = node else { return node }
        if case .leaf = a { return b }
        return .split(id, axis: axis, ratio: ratio, a: withoutFirst(a), b: b)
    }

    /// `node` with `ratio` in the first split that shares its room's height, on the way to the first pane. Nil: no
    /// split on that way does.
    static func rowsRatio(_ ratio: Double, of node: SplitNode) -> SplitNode? {
        guard case let .split(id, axis, old, a, b) = node else { return nil }
        if axis == .vertical { return .split(id, axis: axis, ratio: ratio, a: a, b: b) }
        return rowsRatio(ratio, of: a).map { .split(id, axis: axis, ratio: old, a: $0, b: b) }
    }

    /// `node` after a divider's drag to `ratio`: of the first split that shares its room's height, or with none of
    /// the first split. A split whose room is below the least sizes of its panes shares the room by those sizes and
    /// does not use its ratio (`SplitGeometry.firstExtent`). The test window has the room for the least heights of
    /// the panes at each count of ``pictureCounts``; it has not the room for the least widths of 30 panes.
    static func resized(_ node: SplitNode, to ratio: Double) -> SplitNode {
        if let rows = rowsRatio(ratio, of: node) { return rows }
        guard case let .split(id, axis, _, a, b) = node else { return node }
        return .split(id, axis: axis, ratio: ratio, a: a, b: b)
    }

    /// `count` panes in halves over a window's picture at rest, then the act of `scene` (``pictureScenes``).
    /// `speed`: the motion's springs have this speed, not the app's setting. `padding`: the model has its own style
    /// with this padding around each pane's content, and each pane's content has a header. `configure` sets the
    /// model up more. `before` runs at rest directly before a zoom, an unzoom or a lone close: the screen still shows
    /// the layout before the act.
    static func overPicture(_ scene: String, panes count: Int, gap: String? = nil, speed: MotionSpeed? = nil, padding: CGFloat = 0,
                            configure: (LayoutModel) -> Void = { _ in }, before: (Commit.Harness) -> Void = { _ in }) throws -> OverPicture {
        let more = scene == "second close" || scene == "resize"
        let harness = Commit.Harness(Commit.screen(tree(more ? count + 1 : count)), focused: "p", holds: false, headed: padding > 0) { model in
            if scene != "resize" { model.splitSizingOverride = .even }
            configure(model)
            guard padding > 0 else { return }
            model.followsDesignMetrics = false
            model.baseStyle.panePadding = padding
        }
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        let backdrop = picture(under: harness, gap: gap)
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        screen.zoomDim.motion.speed = speed
        let rest = paneHosts(screen).filter { !$0.isHidden }
        let far = try #require(rest.max { $0.frame.minX + $0.frame.minY < $1.frame.minX + $1.frame.minY }, "SETUP: the screen shows no pane at rest")
        func show() {
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(dt)
        }
        func closeFocused() throws {
            let pane = try #require(harness.model.focusedPane, "SETUP: no pane has the focus")
            _ = try #require(harness.model.showPaneClose(pane), "SETUP: the model does not show the close of \(pane)")
            show()
        }
        switch scene {
        case "zoom", "unzoom":
            harness.model.focus(far.pane, notify: false)
            Commit.rest(harness)
            if scene == "zoom" { before(harness) }
            harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
            show()
            guard scene == "unzoom" else { break }
            Commit.rest(harness)
            try #require(!inFlight(screen), "SETUP: the zoom did not come to rest")
            let content = try #require(harness.provider.contents[far.pane], "SETUP: the zoomed pane has no content")
            let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            last.autoresizingMask = [.width, .height]
            area.addSubview(last)
            content.addSubview(area)
            before(harness)
            harness.model.apply(screens: Commit.screen(tree(count)))
            show()
        case "split, held":
            for content in harness.provider.contents.values {
                let area = PaneContentAreaView(frame: content.bounds), holder = Holder()
                area.autoresizingMask = [.width, .height]
                holder.frame = area.bounds
                holder.autoresizingMask = [.width, .height]
                holder.content = content
                area.addSubview(holder)
                content.addSubview(area)
            }
            harness.model.apply(screens: Commit.screen(tree(count + 1)))
            show()
        case "second close":
            try closeFocused()
            for _ in 0..<3 { _ = harness.root.advanceFrame(dt) }
            try closeFocused()
            try #require(acts(on: screen).count == 2, "SETUP: the panes have the moves of \(acts(on: screen).count) acts, not of the 2 closes")
        case "resize":
            let closed = withoutFirst(tree(count + 1))
            harness.model.apply(screens: Commit.screen(closed))
            show()
            let was = rest.map(\.frame)
            harness.model.apply(screens: Commit.screen(resized(closed, to: 0.35)))
            show()
            try #require(zip(rest, was).contains { $0.0.frame != $0.1 },
                         "SETUP: the resize in the move changes no pane's frame: the split has no room for its panes' least sizes")
        default:
            before(harness)
            try closeFocused()
        }
        try #require(inFlight(screen), "SETUP: no pane moves at the \(scene) of \(count) panes")
        begun = true
        return OverPicture(harness: harness, screen: screen, backdrop: backdrop)
    }

    /// Where `copy` on the layer of `host` shows in the window, when the moves of each act are at `part(act)` of
    /// their way: the copy's rect in its pane's own coordinates, put where the pane's layer shows on its screen. A
    /// copy in the layer of the pane's clip is that clip's place farther in.
    static func windowRect(of copy: CALayer, on host: PaneHostView, in screen: ScreenContentView, at part: (Int) -> CGFloat) -> CGRect? {
        guard let layer = host.layer else { return nil }
        let cell = rect(of: layer, at: part), own = origin(of: layer, at: part), inner = rect(of: copy, at: part)
        let inClip: Bool = copy.superlayer != nil && copy.superlayer === host.clipView.layer
        let clip = inClip ? host.clipView.frame.origin : .zero
        return screen.convert(inner.offsetBy(dx: cell.minX - own.x + clip.x, dy: cell.minY - own.y + clip.y), to: nil)
    }

    /// Each pane that moves over a window's picture has one copy of the picture under it. At the start, at each
    /// quarter and at the end of its move the copy shows the picture where the window has it, within half a point,
    /// and it covers its pane's whole cell: the picture does not go with the pane. Each act of ``pictureScenes``,
    /// with 2, 6 and 30 panes. A second act has its own timing: the frames are read with the act before farther on.
    @Test(arguments: pictureScenes, pictureCounts)
    func thePictureUnderAPaneThatMovesStaysWhereTheWindowHasIt(_ scene: String, _ count: Int) throws {
        let over = try Self.overPicture(scene, panes: count)
        defer { over.harness.window.closeAfterTest() }
        let screen = over.screen, art = over.backdrop.artView
        let want = art.convert(art.bounds, to: nil)
        let acts = Self.acts(on: screen), last = acts.last ?? 0
        let movers = Self.paneHosts(screen).filter { Self.moves($0) }
        let slides = movers.filter { host in
            guard let layer = host.layer else { return false }
            let move = Self.move(of: layer)
            return move.start.origin != move.end.origin
        }
        try #require(!slides.isEmpty, "SETUP: no pane's origin moves at the \(scene) of \(count) panes")
        for host in movers {
            let copies = Self.pictures(on: host)
            #expect(copies.count == 1, "at the \(scene) the pane \(host.pane) moves with \(copies.count) copies of the window's picture under it")
            guard let copy = copies.first, let layer = host.layer else { continue }
            for part in Self.quarters {
                let at: (Int) -> CGFloat = { $0 == last ? part : (1 + part) / 2 }
                let cell = screen.convert(Self.rect(of: layer, at: at), to: nil)
                let shows = Self.windowRect(of: copy, on: host, in: screen, at: at) ?? .zero
                #expect(Commit.near(shows, want),
                        "at \(part) of the \(scene)'s move the copy under \(host.pane) shows the picture at \(shows) in the window; the window has it at \(want)")
                #expect(shows.insetBy(dx: -0.51, dy: -0.51).contains(cell),
                        "at \(part) of the \(scene)'s move the copy under \(host.pane) shows at \(shows) and does not cover its pane's cell \(cell)")
            }
        }
    }

    /// The copy is the window's picture as the window shows it: the same image, fitted the same way, with one layer
    /// of the window's tint over all of it. It is under each other layer of its pane, it has no transform, and the
    /// pane's layer clips it. The pane has no colour on its layer. After the motion's end no pane has a copy.
    @Test func theCopyShowsTheWindowsPictureWithItsTintAndGoesAtTheMotionsEnd() throws {
        let over = try Self.overPicture("close", panes: 2)
        defer { over.harness.window.closeAfterTest() }
        let art = try #require(over.backdrop.artView.layer, "SETUP: the window's picture has no layer")
        let tint = try #require(over.backdrop.shownTintLayer?.backgroundColor, "SETUP: the window shows no tint over its picture")
        let hosts = Self.paneHosts(over.screen)
        let host = try #require(hosts.first { !Self.pictures(on: $0).isEmpty }, "no pane has a copy of the window's picture under it in the close's move")
        let copy = try #require(Self.pictures(on: host).first)
        let image = copy.contents.map { $0 as AnyObject }, shown = art.contents.map { $0 as AnyObject }
        let sameImage: Bool = image != nil && image === shown // outside the macro, as in the backdrop's row below
        #expect(sameImage, "the copy does not show the image that the window's picture shows")
        #expect(copy.contentsGravity == art.contentsGravity && copy.contentsScale == art.contentsScale,
                "the copy fits its image by \(copy.contentsGravity.rawValue) at scale \(copy.contentsScale); the window's picture by \(art.contentsGravity.rawValue) at \(art.contentsScale)")
        let tints = (copy.sublayers ?? []).filter { $0.backgroundColor != nil }
        #expect(tints.count == 1 && (copy.sublayers ?? []).count == 1, "the copy has \(tints.count) tint layers in \((copy.sublayers ?? []).count) layers")
        #expect(Self.rgba(tints.first?.backgroundColor) == Self.rgba(tint),
                "the copy's tint is \(String(describing: Self.rgba(tints.first?.backgroundColor))); the window shows \(String(describing: Self.rgba(tint)))")
        #expect(tints.first?.frame == copy.bounds, "the tint covers \(String(describing: tints.first?.frame)) of the copy's \(copy.bounds)")
        // The layers of a view's subviews come into the view's layer at a display, and this window has none: the
        // row reads the copy's own place in the order, and each other layer that is there.
        let others = (host.layer?.sublayers ?? []).filter { $0 !== copy }
        let lowest: Bool = host.layer?.sublayers?.first === copy
        #expect(lowest && copy.zPosition < 0 && others.allSatisfy { $0.zPosition > copy.zPosition }, "the copy is not under each other layer of its pane")
        #expect(host.layer?.masksToBounds == true && host.layer?.backgroundColor == nil, "the pane's layer does not clip the copy, or it has a colour")
        // The system turns a layer's image itself where the geometry is flipped: the copy needs no turn of its own.
        let flips = [art, host.layer, copy].map { $0?.contentsAreFlipped() }
        print("PICTURE FLIP: contentsAreFlipped() of the layer of the window's picture, of the pane's layer and of the copy = \(flips)")
        #expect(CATransform3DIsIdentity(copy.transform), "the copy has a transform")

        _ = Self.toTheEnd(over.harness, over.screen)
        let left = hosts.flatMap { Self.pictures(on: $0) }
        #expect(left.isEmpty && !Self.inFlight(over.screen), "after the motion's end \(left.count) copies of the window's picture stay on the pane hosts")
    }

    /// The backdrop's own read: with a picture and a tint it gives the image, the picture's frame in the window and
    /// the tint as it shows. A second image is not the same picture. An opaque backdrop shows no picture.
    @Test func theBackdropReadsAsItsStillPictureWithItsTint() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.left, holds: false)
        defer { harness.window.closeAfterTest() }
        let backdrop = Self.picture(under: harness)
        func still() -> WindowStillPicture? {
            if case .still(let picture) = backdrop.stillPicture { return picture }
            return nil
        }
        let picture = try #require(still(), "a backdrop with a picture and a tint does not read as a still picture")
        let image: AnyObject? = picture.contents as AnyObject, shown: AnyObject? = backdrop.artView.layer?.contents.map { $0 as AnyObject }
        // The compare is outside the macro: inside it, the identity compare of 2 values of the type `AnyObject?` made
        // the compiler stop with a fatal error (Swift 6.3.3, in the code that the macro makes for the 2 operands).
        let sameImage: Bool = image === shown
        #expect(sameImage, "the read gives another image than the picture's layer shows")
        #expect(picture.frame == backdrop.artView.convert(backdrop.artView.bounds, to: nil), "the read gives the frame \(picture.frame)")
        #expect(picture.tint != nil && Self.rgba(picture.tint) == Self.rgba(backdrop.shownTintLayer?.backgroundColor),
                "the read gives the tint \(String(describing: Self.rgba(picture.tint)))")
        #expect(picture.isSame(as: picture), "a picture is not the same as itself")
        backdrop.showArt(NSImage(size: NSSize(width: 320, height: 200)))
        let second = try #require(still(), "the backdrop with a second image does not read as a still picture")
        #expect(!second.isSame(as: picture), "a second image reads as the same picture")
        backdrop.apply(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0), tint: .black)
        var gap: WindowPictureGap?
        if case .gap(let why) = backdrop.stillPicture { gap = why }
        #expect(gap == .noPicture, "an opaque backdrop reads as \(String(describing: gap))")
    }

    /// The reasons for which a backdrop is no still picture, as far as a test can make them (a video and a living
    /// wallpaper need a real selection, and Liquid Glass its system).
    nonisolated static let pictureGaps = ["noPicture", "blur", "seeThrough", "changing"]

    /// A window whose backdrop is no still picture: the read names the reason, a close moves its panes, and no pane
    /// gets a copy or a colour. Such a window shows what the base shows.
    @Test(arguments: pictureGaps)
    func aWindowWithNoStillPictureGivesAPaneThatMovesNoGround(_ gap: String) throws {
        let over = try Self.overPicture("close", panes: 2, gap: gap)
        defer { over.harness.window.closeAfterTest() }
        var why: String?
        if case .gap(let reason) = over.backdrop.stillPicture { why = reason.rawValue }
        #expect(why == gap, "the backdrop reads as \(why ?? "a still picture"), not as \(gap)")
        let grounds = Self.paneHosts(over.screen).filter { !Self.pictures(on: $0).isEmpty || $0.layer?.backgroundColor != nil }.map(\.pane)
        #expect(grounds.isEmpty, "with \(gap) the panes \(grounds) have a copy of the picture or a colour on their layer")
    }

    /// The window's picture or its tint changes while the panes move: the next frame tick ends the move. Each pane
    /// is at its place and no pane keeps a copy of the picture that the window showed before.
    @Test(arguments: ["a new picture", "a new tint"])
    func aChangeOfTheWindowsPictureInAMoveEndsTheMove(_ change: String) throws {
        let over = try Self.overPicture("close", panes: 2)
        defer { over.harness.window.closeAfterTest() }
        let hosts = Self.paneHosts(over.screen)
        try #require(hosts.contains { !Self.pictures(on: $0).isEmpty }, "no pane has a copy of the window's picture under it in the close's move")
        if change == "a new picture" {
            over.backdrop.showArt(NSImage(size: NSSize(width: 320, height: 200)))
        } else {
            over.backdrop.apply(WindowBackdrop(backgroundOpacity: 0.4, backgroundBlur: 0), tint: .black)
        }
        _ = over.harness.root.advanceFrame(Self.dt)
        let left = hosts.flatMap { Self.pictures(on: $0) }
        #expect(!Self.inFlight(over.screen), "after \(change) in the move the panes still move")
        #expect(left.isEmpty, "after \(change) in the move \(left.count) copies of the old picture stay")
    }

    /// A hold of the close key over a picture: 10 closes, each in the move of the one before. After the fourth key
    /// and after the tenth each pane that moves has one copy and no pane has 2, and no pane of the layout has a mask
    /// on its clip: only a pane that the move keeps under one pane that moves has one (`PaneCommitMotion+Under`).
    /// At rest after the hold no pane has a copy or a mask.
    @Test func aHoldOfTheCloseKeyOverAPictureKeepsOneCopyForEachPaneThatMoves() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(12)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        _ = Self.picture(under: harness)
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let all = Self.paneHosts(screen).filter { !$0.isHidden }
        try #require(all.count == 12, "SETUP: the screen shows \(all.count) panes at rest, not 12")
        for key in 1...10 {
            let pane = try #require(harness.model.focusedPane, "SETUP: no pane has the focus before key \(key)")
            _ = try #require(harness.model.showPaneClose(pane), "SETUP: the model does not show the close of \(pane) at key \(key)")
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
            try #require(Self.inFlight(screen), "SETUP: key \(key) ended the motion")
            guard key == 4 || key == 10 else { continue }
            let piles = all.filter { Self.pictures(on: $0).count > 1 }.map(\.pane)
            let bare = all.filter { Self.moves($0) && Self.pictures(on: $0).isEmpty }.map(\.pane)
            let masks = all.filter { !$0.isLeaving && $0.clipView.layer?.mask != nil }.map(\.pane)
            #expect(piles.isEmpty, "after key \(key) the panes \(piles) have more than 1 copy of the window's picture")
            #expect(bare.isEmpty, "after key \(key) the panes \(bare) move with no copy of the window's picture under them")
            #expect(masks.isEmpty, "after key \(key) the panes \(masks) of the layout have a mask on their clip")
        }
        Commit.rest(harness)
        let left = all.flatMap { Self.pictures(on: $0) }
        #expect(left.isEmpty, "at rest after the hold \(left.count) copies of the window's picture stay on the pane hosts")
        let masks = all.filter { $0.clipView.layer?.mask != nil }.map(\.pane)
        #expect(masks.isEmpty, "at rest after the hold the panes \(masks) have a mask on their clip")
    }

    /// A close of one of 2 panes of a column at the screen's edge, over a window's picture. The pane that grows has
    /// under its content what is under that column's panes at rest. In the `docked` mode that is the window's
    /// picture: one copy, and no colour. In the `overlay` mode it is the opaque ground of the column's backdrop: a
    /// colour of alpha 1 on the pane's layer, and no copy.
    @Test(arguments: dockModes)
    func overAPictureAPaneOfAColumnAtTheEdgeHasWhatIsUnderItAtRest(_ mode: String) throws {
        let dock = try #require(DockMode(rawValue: mode), "SETUP: no dock mode \(mode)")
        let harness = Commit.Harness(Self.dockRows(dock), focused: "notes", holds: false)
        defer { harness.window.closeAfterTest() }
        _ = Self.picture(under: harness)
        Self.movePanes(harness)
        Commit.rest(harness)
        harness.model.apply(screens: Self.dockRows(dock, rows: false))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let host = try #require(harness.root.context.hosts["chat"], "SETUP: the pane that stays has no host")
        try #require(Self.moves(host), "SETUP: the pane that stays does not move at the close")
        let copies = Self.pictures(on: host).count, alpha = host.layer?.backgroundColor?.alpha
        let wanted = dock == .overlay ? "no copy and a colour of alpha 1" : "1 copy and no colour"
        #expect(dock == .overlay ? copies == 0 && (alpha ?? 0) >= 1 : copies == 1 && alpha == nil,
                "in the \(mode) mode the pane that grows has \(copies) copies of the window's picture and a colour of alpha \(String(describing: alpha)) on its layer; it must have \(wanted)")
    }
}
