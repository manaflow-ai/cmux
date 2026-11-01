import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// What a click lands on around the sidebar's edge facing the content, where the resize band and
/// the list's scroller meet (Lawrence 2026-10-30, msg 18056: "hitbox for the sidebar resize /
/// sidebar scrollbar needs to be improved"). The map sweeps real `hitTest` calls through the
/// window's frame view, so it measures the shipped routing, not a model of it. It also writes the
/// map over a render of the window in light and dark (`artifacts/sidebar-hitmap/hitmap.png`, git-ignored) for the
/// before/after shots: red takes a resize, blue the scroller.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEdgeHitMapTests {
    enum Target: Equatable { case resize, scroller, other }

    struct Fixture {
        let window: NSWindow
        let root: WindowRootView
        let handle: SidebarResizeHandle
        let scroller: ThinScroller
    }

    /// A window whose sidebar list overflows, with its scroller's knob shown (a scroll just ran).
    static func fixture(appearance: NSAppearance.Name? = nil) throws -> Fixture {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<80).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces)])
        let container = SidebarContainerView(model: model)
        let root = WindowRootView(sidebar: container)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.appearance = appearance.flatMap(NSAppearance.init(named:))
        window.contentView = root
        container.sidebarView.renderNow()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        let scroller = try #require(container.sidebarView.scrollView.verticalScroller as? ThinScroller)
        scroller.flash()
        return Fixture(window: window, root: root, handle: container.handle, scroller: scroller)
    }

    static func target(atX x: CGFloat, y: CGFloat, in f: Fixture) -> Target {
        guard let frameView = f.window.contentView?.superview else { return .other }
        let point = f.root.convert(CGPoint(x: x, y: y), to: nil)
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        if hit === f.handle { return .resize }
        if hit === f.scroller { return .scroller }
        return .other
    }

    /// The drawn knob, in root coordinates.
    static func knob(_ f: Fixture) throws -> CGRect {
        let knob = try #require(f.scroller.restingKnobFrame, "the knob shows after a scroll")
        return f.scroller.convert(knob, to: f.root)
    }

    /// Points of the row at `y` that land on `target`, swept every 0.25 pt within 30 pt of the edge.
    static func width(of target: Target, atY y: CGFloat, in f: Fixture) -> CGFloat {
        let edge = f.root.sidebar.frame.maxX
        let step: CGFloat = 0.25
        return stride(from: edge - 30, to: edge + 30, by: step)
            .filter { Self.target(atX: $0, y: y, in: f) == target }.count.cgFloat * step
    }

    @Test func measureAndDrawTheEdgeHitAreas() throws {
        var shots: [CGImage] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            shots.append(try Self.measure(appearance: appearance))
        }
        try Self.write(shots)
    }

    /// Prints the hit widths around the edge in `appearance` and returns the tinted render.
    static func measure(appearance: NSAppearance.Name) throws -> CGImage {
        let f = try Self.fixture(appearance: appearance)
        defer { f.window.close() }
        let knob = try Self.knob(f)
        let edge = f.root.sidebar.frame.maxX
        let besideKnob = knob.maxY + 40 < f.root.bounds.maxY - 40 ? knob.maxY + 40 : knob.minY - 40
        let numbers = [
            "edge": edge,
            "knob.minX": knob.minX, "knob.maxX": knob.maxX, "knob.height": knob.height,
            "resize@knob": Self.width(of: .resize, atY: knob.midY, in: f),
            "scroller@knob": Self.width(of: .scroller, atY: knob.midY, in: f),
            "resize@row": Self.width(of: .resize, atY: besideKnob, in: f),
        ]
        print("sidebar-hitmap", appearance.rawValue, numbers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        #expect(numbers["resize@row"] ?? 0 >= 8)
        return try Self.draw(f, knob: knob)
    }

    /// The band's inner 4 pt lay over the list's scroller: a press on the outer part of the shown
    /// knob (2 of its 7 pt wide, 2 of 3 pt thin) started a resize instead of a scroll.
    @Test func everyPointOfTheShownKnobScrolls() throws {
        let f = try Self.fixture()
        defer { f.window.close() }
        let knob = try Self.knob(f)
        for x in stride(from: knob.minX + 0.25, to: knob.maxX, by: 0.5) {
            for y in [knob.minY + 1, knob.midY, knob.maxY - 1] {
                #expect(Self.target(atX: x, y: y, in: f) == .scroller, "a press at x \(x - f.root.sidebar.frame.maxX) pt from the edge")
            }
        }
    }

    /// Beside the knob (above or below it) the band keeps its full width on both sides of the edge: its
    /// `SidebarResizeBand.contentInset` (2 pt, #27954) inside the sidebar and the gutter outside it.
    @Test func theBandKeepsItsWidthBesideTheKnob() throws {
        let f = try Self.fixture()
        defer { f.window.close() }
        let knob = try Self.knob(f)
        let edge = f.root.sidebar.frame.maxX
        let y = knob.maxY + 40 < f.root.bounds.maxY - 40 ? knob.maxY + 40 : knob.minY - 40
        for offset: CGFloat in [-1.5, -1, -0.5, 0.5, 2, 4, 5.5] {
            #expect(Self.target(atX: edge + offset, y: y, in: f) == .resize, "a press \(offset) pt from the edge")
        }
        #expect(Self.width(of: .resize, atY: y, in: f) >= 8)
    }

    /// Over the knob the cursor is the arrow (the press scrolls); beside it, the resize cursor.
    @Test func theCursorFollowsWhoTakesThePress() throws {
        let f = try Self.fixture()
        defer { f.window.close() }
        let knob = try Self.knob(f)
        let edge = f.root.sidebar.frame.maxX
        let overKnob = f.root.convert(CGPoint(x: min(knob.maxX - 0.5, edge - 1), y: knob.midY), to: nil)
        let besideY = knob.maxY + 40 < f.root.bounds.maxY - 40 ? knob.maxY + 40 : knob.minY - 40
        let beside = f.root.convert(CGPoint(x: edge - 1, y: besideY), to: nil)
        #expect(!f.handle.showsResizeCursor(at: overKnob))
        #expect(f.handle.showsResizeCursor(at: beside))
    }

    /// Renders the window around the edge at 4x with every point's click target tinted.
    static func draw(_ f: Fixture, knob: CGRect) throws -> CGImage {
        let edge = f.root.sidebar.frame.maxX
        let region = CGRect(x: edge - 48, y: max(0, knob.midY - 90), width: 80, height: 180)
        let scale: CGFloat = 4
        let rep = try #require(f.root.bitmapImageRepForCachingDisplay(in: f.root.bounds))
        f.root.cacheDisplay(in: f.root.bounds, to: rep)
        let out = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale), pixelsHigh: Int(region.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: out))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        var background = NSColor.windowBackgroundColor.cgColor, label = NSColor.labelColor.cgColor
        f.root.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
            label = NSColor.labelColor.cgColor
        }
        cg.setFillColor(background)
        cg.fill(CGRect(origin: .zero, size: CGSize(width: region.width * scale, height: region.height * scale)))
        // The root is flipped: draw its render with y going down, then tint in the same space.
        cg.translateBy(x: 0, y: region.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -region.minX, y: -region.minY)
        if let image = rep.cgImage {
            cg.saveGState()
            cg.translateBy(x: 0, y: f.root.bounds.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: f.root.bounds.size))
            cg.restoreGState()
        }
        let step: CGFloat = 0.25
        for y in stride(from: region.minY, to: region.maxY, by: 1) {
            for x in stride(from: region.minX, to: region.maxX, by: step) {
                switch Self.target(atX: x, y: y + 0.5, in: f) {
                case .resize: cg.setFillColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
                case .scroller: cg.setFillColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
                case .other: continue
                }
                cg.fill(CGRect(x: x, y: y, width: step, height: 1))
            }
        }
        cg.setStrokeColor(NSColor.systemGreen.cgColor)
        cg.setLineWidth(1 / scale)
        cg.stroke(knob)
        cg.setStrokeColor(label)
        cg.move(to: CGPoint(x: edge, y: region.minY)); cg.addLine(to: CGPoint(x: edge, y: region.maxY)); cg.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(out.cgImage)
    }

    /// Writes the shots side by side, light first.
    static func write(_ shots: [CGImage]) throws {
        let gap = 16, width = shots.map(\.width).reduce(0, +) + gap * (shots.count - 1), height = shots.map(\.height).max() ?? 0
        let out = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: out))
        var x = 0
        for shot in shots {
            context.cgContext.draw(shot, in: CGRect(x: x, y: height - shot.height, width: shot.width, height: shot.height))
            x += shot.width + gap
        }
        let png = try #require(out.representation(using: .png, properties: [:]))
        let repo = URL(filePath: #filePath).deletingLastPathComponent() // CmuxNextAppTests
            .deletingLastPathComponent().deletingLastPathComponent() // CmuxNext
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // repo root
        let dir = repo.appending(path: "artifacts/sidebar-hitmap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "hitmap.png"))
    }
}

private extension Int {
    var cgFloat: CGFloat { CGFloat(self) }
}
