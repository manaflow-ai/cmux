import AppKit
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreGraphics
import Foundation
import Testing

/// The picture rules of p08-startup-102, one test per rule: a window full screen or on another Space at the quit
/// leaves no picture; the launch compares the layout per region against the window it opens from the prefetched
/// launch snapshot, and a changed region is cut out of the picture while the rest shows (a workspace the CLI closed
/// while the app was closed changes the sidebar only); the launch builds its layout as the quit wrote it; and the
/// picture is never stretched, the cut included. The backdrop rule (the quit draws the root without the material) is
/// `WindowPictureStoreTests.theCaptureLeavesTheBackdropOut`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowPictureMetaTests {
    nonisolated static let launch = WindowPictureStore.LaunchFacts(savedPicture: true, recovered: false, incognitoLeftovers: false)
    nonisolated static let size = CGSize(width: 1100, height: 720)
    nonisolated static let sidebarFrame = CGRect(x: 0, y: 0, width: 240, height: 720)

    static func meta(workspaces: [String] = ["ws_a", "ws_b"], area: WindowPictureMeta.ContentArea = .workspace("ws_a"),
                     tree: WindowPictureMeta.PaneTree = .leaf("1"), sidebar: CGRect? = WindowPictureMetaTests.sidebarFrame) -> WindowPictureMeta {
        let screens = [WindowPictureMeta.Screen(id: "scr_1", tree: tree, zoomed: nil)]
        var regions = [WindowPictureMeta.Region(kind: .pane, id: "tab_a", frame: CGRect(x: 240, y: 40, width: 860, height: 680))]
        if let sidebar { regions.insert(.init(kind: .sidebar, id: "sidebar", frame: sidebar), at: 0) }
        return WindowPictureMeta(window: "0b5c7d3e-6f1a-4b2c-9d8e-1f2a3b4c5d6e", profile: "default",
                                 frame: CGRect(origin: CGPoint(x: 100, y: 120), size: size), screen: "DISPLAY-1", scale: 2,
                                 appearance: NSAppearance.Name.darkAqua.rawValue, theme: WindowPictureMeta.fingerprint(["theme"]),
                                 sidebarWidth: sidebar.map { Double($0.width) } ?? 0, build: "1.0 (1)",
                                 layout: area.layout(workspaces: workspaces, screens: screens), regions: regions)
    }

    static func image(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The cut `saved`'s picture gets when the launch opens `opening`; nil, the window takes today's path.
    static func cut(_ saved: WindowPictureMeta, opening: WindowPictureMeta) -> [CGRect]? {
        guard case .show(let stale) = WindowPictureStore.use(saved, for: opening, launch: launch) else { return nil }
        return saved.staleAreas(stale, size: size)
    }

    // MARK: Full screen and Spaces

    @Test func aFullScreenWindowLeavesNoPicture() {
        let eligibility = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: true,
                                                         hiddenFromCapture: false)
        #expect(!eligibility.allowsPicture)
    }

    @Test func aWindowOnAnotherSpaceLeavesNoPicture() {
        let eligibility = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: false, fullScreen: false,
                                                         hiddenFromCapture: false)
        #expect(!eligibility.allowsPicture)
        let shown = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false,
                                                   hiddenFromCapture: false)
        #expect(shown.allowsPicture, "a window on screen, on this Space and windowed leaves one")
    }

    // MARK: The layout, per region

    @Test func anUnchangedLayoutCutsNothing() {
        #expect(Self.cut(Self.meta(), opening: Self.meta()) == [])
    }

    /// The matrix case: a workspace the CLI closed while the app was closed (not the shown one) changes the sidebar's
    /// rows only. The sidebar is cut out; the content area still shows its picture.
    @Test func aWorkspaceClosedWhileClosedCutsOnlyTheSidebar() {
        let closed = Self.meta(workspaces: ["ws_a"])
        #expect(Self.meta().mismatches(closed) == [.sidebarLayout])
        #expect(Self.cut(Self.meta(), opening: closed) == [Self.sidebarFrame])
    }

    /// A changed pane tree cuts everything beside the sidebar's column: the panes, their strips and the dividers all
    /// follow the tree.
    @Test func aChangedPaneTreeCutsTheContentAreaOnly() {
        let split = Self.meta(tree: .split(vertical: false, ratio: 0.5, a: .leaf("1"), b: .leaf("2")))
        #expect(Self.meta().mismatches(split) == [.contentLayout])
        #expect(Self.cut(Self.meta(), opening: split) == [CGRect(x: 240, y: 0, width: 860, height: 720)])
        let right = Self.meta(sidebar: CGRect(x: 860, y: 0, width: 240, height: 720))
        var splitRight = right
        splitRight.layout = split.layout
        #expect(right.staleAreas([.pane], size: Self.size) == [CGRect(x: 0, y: 0, width: 860, height: 720)],
                "a sidebar on the right keeps its column too")
        #expect(Self.cut(right, opening: splitRight) == [CGRect(x: 0, y: 0, width: 860, height: 720)])
    }

    /// The shown workspace closed changes both regions: nothing of the picture is right, so today's path.
    @Test func bothRegionsChangedTakeTodaysPath() {
        let closedShown = Self.meta(workspaces: ["ws_b"], area: .workspace("ws_b"), tree: .leaf("2"))
        #expect(Self.meta().mismatches(closedShown) == [.sidebarLayout, .contentLayout])
        #expect(Self.cut(Self.meta(), opening: closedShown) == nil)
    }

    @Test func aChangedContentWithNoSidebarTakesTodaysPath() {
        let hidden = Self.meta(sidebar: nil)
        #expect(hidden.staleAreas([.pane], size: Self.size) == nil, "the content is the whole picture")
        #expect(hidden.staleAreas([.sidebar], size: Self.size) == [], "a hidden sidebar shows no rows to cut")
    }

    @Test func theCutStaysInsideThePictureAndNeverOverlaps() throws {
        let wide = Self.meta(sidebar: CGRect(x: 0, y: -10, width: 2000, height: 900))
        #expect(wide.staleAreas([.sidebar], size: Self.size) == [CGRect(origin: .zero, size: Self.size)])
        let middle = Self.meta(sidebar: CGRect(x: 300, y: 0, width: 240, height: 720))
        let areas = try #require(middle.staleAreas([.pane], size: Self.size))
        #expect(areas == [CGRect(x: 0, y: 0, width: 300, height: 720), CGRect(x: 540, y: 0, width: 560, height: 720)])
        #expect(!areas[0].intersects(areas[1]))
    }

    /// The launch builds each region's digest from the window's saved state the way the quit wrote it
    /// (`ContentArea.init(page:workspaceID:cloudCreating:contentShown:)`), so an unchanged window matches.
    @Test func theLaunchsLayoutIsTheQuitsForTheSameWindow() throws {
        let screens = [WindowPictureMeta.Screen(id: "scr_1", tree: .leaf("1"), zoomed: nil)]
        for (page, workspace) in [(String?.some("settings"), String?.some("ws_a")), (nil, "ws_a"), (nil, nil)] {
            let quit = try #require(WindowPictureMeta.ContentArea(page: page, workspaceID: workspace, cloudCreating: false, contentShown: true))
            let launch = WindowPictureMeta.ContentArea(page: page, workspaceID: workspace)
            #expect(launch == quit)
            #expect(launch.layout(workspaces: ["ws_a"], screens: screens) == quit.layout(workspaces: ["ws_a"], screens: screens))
        }
        #expect(WindowPictureMeta.ContentArea(page: "settings", workspaceID: "ws_a").layout(workspaces: [], screens: [])
                != WindowPictureMeta.ContentArea(page: nil, workspaceID: "ws_a").layout(workspaces: [], screens: []),
                "a page over the workspace is another content area")
    }

    // MARK: Never stretched

    /// The picture layer shows the image at the picture's own scale, pinned to the top-left: a window taller or
    /// wider than the picture shows it 1:1 and the live material beside it, never a stretched picture.
    @Test func thePictureIsNeverStretched() throws {
        let image = try Self.image(width: 2200, height: 1440)
        let view = LaunchPictureView(image: image, scale: 2)
        view.frame = NSRect(x: 0, y: 0, width: 1300, height: 800)
        view.updateLayer()
        let picture = view.pictureLayer
        #expect(picture.superlayer === view.layer, "the picture layer is the view's only layer")
        #expect(picture.contents.map { $0 as AnyObject } === image as AnyObject)
        #expect(picture.contentsGravity == .topLeft, "pinned to a corner, so no resize gravity scales it")
        #expect(picture.contentsScale == 2, "2 pixels per point: 2200 x 1440 pixels cover 1100 x 720 points")
        #expect(picture.frame == view.bounds)
        #expect(picture.masksToBounds)
        #expect(picture.mask == nil, "nothing is cut")
        #expect(view.layer?.contents == nil, "the view's own layer has no pixels: AppKit resets its scale to the window's")
    }

    /// The cut is placed from the picture's top: in an unflipped view the top is the maximum y, so a sidebar cut stays
    /// at the window's top-left corner whatever the window's height.
    @Test func theCutIsPlacedFromThePicturesTop() throws {
        let image = try Self.image(width: 2200, height: 1440)
        let view = LaunchPictureView(image: image, scale: 2, cut: [CGRect(x: 0, y: 0, width: 240, height: 700)])
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        view.updateLayer()
        let mask = try #require(view.pictureLayer.mask as? CAShapeLayer)
        #expect(mask.fillRule == .evenOdd)
        #expect(mask.frame == view.pictureLayer.bounds)
        #expect(mask.path?.contains(CGPoint(x: 600, y: 400), using: .evenOdd) == true, "the content area shows")
        #expect(mask.path?.contains(CGPoint(x: 100, y: 750), using: .evenOdd) == false, "the sidebar's top is cut")
        #expect(mask.path?.contains(CGPoint(x: 100, y: 50), using: .evenOdd) == true, "below the cut's 700 points, it shows")
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        #expect(mask.path?.contains(CGPoint(x: 100, y: 850), using: .evenOdd) == false, "a resize moves the cut with the top")
    }

    @Test func aCutAreaIsPlacedInLayerCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let area = CGRect(x: 10, y: 0, width: 20, height: 30)
        #expect(LaunchPictureView.layerRect(area, in: bounds, flipped: false) == CGRect(x: 10, y: 50, width: 20, height: 30))
        #expect(LaunchPictureView.layerRect(area, in: bounds, flipped: true) == area)
        #expect(LaunchPictureView.layerRect(CGRect(x: 0, y: 70, width: 100, height: 30), in: bounds, flipped: false)
                == CGRect(x: 0, y: 0, width: 100, height: 10), "clipped to the layer")
        #expect(LaunchPictureView.layerRect(CGRect(x: 200, y: 0, width: 10, height: 10), in: bounds, flipped: false) == .zero)
    }

    @Test func thePhaseShowsThePictureAtItsOwnScaleWithItsCut() throws {
        let phase = LaunchPicturePhase(deadlines: MainDeadlineScheduler(work: .still())) { _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cut = [Self.sidebarFrame]
        phase.show(try Self.image(width: 3300, height: 2160), scale: 3, cut: cut, in: window, scope: ThemeScope(level: .room), present: {},
                   startup: nil) {}
        let picture = try #require(phase.picture)
        #expect(picture.scale == 3, "the picture's scale, not the window's")
        #expect(picture.frame.size == Self.size)
        #expect(picture.cut == cut)
    }
}
