import AppKit
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreGraphics
import Foundation
import Testing

/// The launch's first frame from the front window's saved picture: the first frame is the window,
/// its live material and one picture layer, nothing else; the window waits for the picture's read at most 40 ms and
/// decides once; a picture whose meta does not match the window the launch opens is never shown (today's path); and
/// the live window is built behind the picture, which leaves when every region showed.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LaunchPictureViewTests {
    static func image(width: Int = 8, height: Int = 6) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    static func meta(frame: CGRect = CGRect(x: 100, y: 120, width: 1100, height: 720), build: String = "1.0 (1)") -> WindowPictureMeta {
        WindowPictureMeta(window: "0b5c7d3e-6f1a-4b2c-9d8e-1f2a3b4c5d6e", profile: "default", frame: frame, screen: "display-1",
                          scale: 2, appearance: NSAppearance.Name.darkAqua.rawValue, theme: "theme", sidebarWidth: 240, build: build,
                          layout: WindowPictureMeta.Layout(workspaces: ["w1", "w2"], shown: "w1",
                                                           screens: [WindowPictureMeta.Screen(id: "s1", tree: .leaf("p1"), zoomed: nil)]),
                          regions: [WindowPictureMeta.Region(kind: .sidebar, id: "sidebar", frame: CGRect(x: 0, y: 0, width: 240, height: 720))])
    }

    static func encoded(_ meta: WindowPictureMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(meta)
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A phase on a scheduler whose frames never run: its deadlines never fire on their own.
    static func phase(_ marks: Marks) -> LaunchPicturePhase {
        LaunchPicturePhase(deadlines: MainDeadlineScheduler(work: .still())) { marks.all.append($0) }
    }

    final class Marks {
        var all: [String] = []
    }

    // MARK: The view

    @Test func thePictureIsOneLayerPinnedTopLeftAtTheWindowsScale() throws {
        let image = try Self.image(width: 2200, height: 1440)
        let view = LaunchPictureView(image: image, scale: 2)
        #expect(view.frame.size == CGSize(width: 1100, height: 720), "the view is the picture's size in points")
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        view.updateLayer()
        let layer = try #require(view.layer)
        #expect(layer.contents.map { $0 as AnyObject } === image as AnyObject, "the layer shows the decoded image itself, no redraw")
        #expect(layer.contentsGravity == .topLeft, "a taller window keeps the picture's titlebar at the top, unstretched")
        #expect(layer.contentsScale == 2)
        #expect(view.wantsUpdateLayer, "the view draws nothing of its own")
        #expect(view.subviews.isEmpty)
    }

    @Test func aClickPassesThroughThePicture() throws {
        let view = LaunchPictureView(image: try Self.image(), scale: 1)
        #expect(view.hitTest(NSPoint(x: 2, y: 2)) == nil)
    }

    @Test func aScaleOfZeroDrawsOnePixelPerPoint() throws {
        let view = LaunchPictureView(image: try Self.image(width: 8, height: 6), scale: 0)
        #expect(view.scale == 1)
        #expect(view.frame.size == CGSize(width: 8, height: 6))
    }

    // MARK: The match

    @Test func aMetaThatMatchesTheWindowShowsThePicture() throws {
        let meta = Self.meta()
        var opening = meta
        opening.regions = [] // the launch knows no regions yet; they are not compared
        #expect(WindowPictureMeta.mismatches(saved: try Self.encoded(meta), opening: opening).isEmpty)
    }

    @Test func aMismatchTakesTodaysPath() throws {
        let saved = try Self.encoded(Self.meta())
        #expect(WindowPictureMeta.mismatches(saved: saved, opening: Self.meta(frame: CGRect(x: 100, y: 120, width: 900, height: 720))) == [.frame])
        #expect(WindowPictureMeta.mismatches(saved: saved, opening: Self.meta(build: "1.0 (2)")) == [.build])
        var otherLayout = Self.meta()
        otherLayout.layout = WindowPictureMeta.Layout(workspaces: ["w1", "w2", "w3"], shown: "w1", screens: [])
        #expect(WindowPictureMeta.mismatches(saved: saved, opening: otherLayout) == [.sidebarLayout, .contentLayout])
    }

    @Test func aMetaThatDoesNotDecodeMatchesNothing() {
        #expect(WindowPictureMeta.mismatches(saved: Data("{\"window\":\"w\"}".utf8), opening: Self.meta()) == Set(WindowPictureMeta.Field.allCases))
        #expect(WindowPictureMeta.mismatches(saved: Data(), opening: Self.meta()) == Set(WindowPictureMeta.Field.allCases))
    }

    // MARK: The wait

    @Test func theReadThatEndsInTimeDecidesOnce() async {
        let marks = Marks()
        let phase = Self.phase(marks)
        let (ends, end) = AsyncStream.makeStream(of: Bool.self)
        var decisions = ends.makeAsyncIterator()
        phase.start({}, on: BackgroundWork(label: "test.launch-picture"), mainWork: .still()) { end.yield($0) }
        #expect(phase.isWaiting)
        phase.decided(inTime: true)
        #expect(await decisions.next() == true)
        #expect(!phase.isWaiting)
        phase.decided(inTime: false) // the deadline after the read: nothing
        end.finish()
        #expect(await decisions.next() == nil, "the window decided twice")
    }

    @Test func atTheDeadlineTheWindowGoesOnWithoutThePicture() async {
        let phase = Self.phase(Marks())
        let (ends, end) = AsyncStream.makeStream(of: Bool.self)
        var decisions = ends.makeAsyncIterator()
        phase.start({}, on: BackgroundWork(label: "test.launch-picture"), mainWork: .still()) { end.yield($0) }
        phase.decided(inTime: false)
        #expect(await decisions.next() == false)
        phase.decided(inTime: true) // a read that ends after the deadline: the window is on today's path already
        end.finish()
        #expect(await decisions.next() == nil)
        #expect(LaunchPicturePhase.wait == .milliseconds(40))
    }

    // MARK: The first frame

    @Test func theFirstFrameIsTheMaterialAndThePictureOnly() throws {
        let marks = Marks()
        let phase = Self.phase(marks)
        let window = Self.window()
        defer { window.close() }
        var presented = 0
        phase.show(try Self.image(width: 2200, height: 1440), in: window, scope: ThemeScope(level: .room), present: { presented += 1 },
                   startup: nil) {}
        let surface = try #require(window.contentView as? WindowSurfaceView)
        #expect(surface.subviews.count == 2)
        #expect(surface.subviews.first is WindowMaterialView, "the live material is the bottom view")
        #expect(surface.subviews.last is LaunchPictureView, "the picture is the only view over it")
        #expect(surface.content === phase.picture)
        #expect(presented == 1)
        #expect(marks.all == ["launch_picture_shown"])
        #expect(!phase.isBuilt, "the controller is built after the first frame, not in it")
    }

    @Test func aMismatchOpensTheWindowAsToday() {
        let phase = Self.phase(Marks())
        var restored = false
        phase.whenBuilt { restored = true }
        #expect(!restored, "work that adopts the controller waits for it")
        phase.skip()
        #expect(phase.isBuilt && restored)
        #expect(phase.picture == nil && phase.window == nil, "no picture shows on today's path")
    }

    /// The picture goes over the live root and leaves region by region: it stays while a region
    /// has no content, and the work that adopts the window waits for its live views, not for the picture.
    @Test func theLiveWindowIsBuiltBehindThePictureWhichLeavesWhenEveryRegionLeft() throws {
        let marks = Marks()
        let phase = Self.phase(marks)
        let window = Self.window()
        defer { window.close() }
        phase.show(try Self.image(), in: window, scope: ThemeScope(level: .room), present: {}, startup: nil) {}
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.addSubview(NSView())
        var restored = false
        phase.whenBuilt { restored = true }
        let reveal = LaunchReveal()
        let regions = try #require(phase.adopt(root: root, reveal: reveal))
        #expect(!restored && !phase.isBuilt, "the live views behind the picture are not built yet")
        let picture = try #require(phase.picture)
        #expect(root.subviews.last === picture, "the picture covers the live root")
        #expect(picture.frame == root.bounds)
        let sidebar = regions.add { _ in CGRect(x: 0, y: 0, width: 240, height: 720) }
        let pane = regions.add { _ in CGRect(x: 240, y: 0, width: 860, height: 690) }
        regions.seal()
        regions.leave(sidebar)
        #expect(picture.superview === root, "the picture stays while a region has no content")
        #expect(!regions.covers(CGPoint(x: 100, y: 300)) && regions.covers(CGPoint(x: 600, y: 300)))
        regions.leave(pane)
        #expect(picture.superview == nil && phase.picture == nil)
        phase.buildFinished()
        #expect(restored && phase.isBuilt)
        #expect(marks.all == ["launch_picture_shown", "launch_picture_removed"])
    }
}
