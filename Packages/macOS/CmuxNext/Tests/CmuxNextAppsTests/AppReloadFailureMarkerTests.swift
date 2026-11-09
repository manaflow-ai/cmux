import AppKit
import CmuxNextDaemon
@testable import CmuxNextApps
import CmuxNextDesign
import Foundation
import Testing
import UniformTypeIdentifiers

/// A customize save whose script does not load keeps the view on the last script that did (the
/// supervisor's `apps-reload-failed`). The view says so with a small marker naming the file and line,
/// and the next good save (a reset scene) takes the marker away.
@MainActor @Suite(.serialized) struct AppReloadFailureMarkerTests {
    static let reason = "init: SyntaxError: expecting ';' at main.js:2:12"

    /// A drawn PR list, as the customize app's section draws it.
    static func drawnList() -> AppSceneModel {
        let model = AppSceneModel()
        model.apply(prOps(first: "Fix sidebar insets"))
        return model
    }

    static func prOps(first: String) -> [AppSceneOp] {
        [
            .create(id: "list", type: "VStack", props: ["spacing": 2]),
            .create(id: "r1", type: "Row", props: ["title": .string(first), "symbol": "arrow.triangle.pull"]),
            .create(id: "r2", type: "Row", props: ["title": "Native new tab page", "subtitle": "manaflow-ai/cmux · Merged", "symbol": "checkmark.circle"]),
            .children(id: "list", children: ["r1", "r2"]),
            .root(id: "list"),
        ]
    }

    static func host(_ model: AppSceneModel, width: CGFloat = 260) -> (NSWindow, AppSceneHostingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    static func all(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all(in: $0) } }

    static func marker(in root: NSView) -> NSView? {
        all(in: root).first { !$0.isHiddenOrHasHiddenAncestor && ($0.accessibilityLabel() ?? "").contains("main.js:2:12") }
    }

    @Test func theSupervisorsReloadFailedEventDecodes() {
        let payload = CmuxNextDaemon.JSONValue.object(["app": .string("local/customize"), "reason": .string(Self.reason)])
        let event = AppsWireDecoding().event(name: "apps-reload-failed", payload: payload)
        #expect(event == .reloadFailed(app: "local/customize", reason: Self.reason))
    }

    @Test func aDrawnViewShowsTheMarkerAndKeepsItsRows() {
        let model = Self.drawnList()
        model.reloadFailure = Self.reason
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        #expect(Self.marker(in: root) != nil, "no marker names the file and line")
        #expect(Self.all(in: root).contains { $0.accessibilityLabel() == "Fix sidebar insets" }, "the last good rows stay")
    }

    @Test func aGoodSaveTakesTheMarkerAway() {
        let model = Self.drawnList()
        model.reloadFailure = Self.reason
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        model.reset()
        model.apply(Self.prOps(first: "Fix sidebar insets again"))
        root.layoutSubtreeIfNeeded()
        (root.subviews.first as? AppSceneNativeView)?.redrawIfNeeded()
        root.layoutSubtreeIfNeeded()
        #expect(model.reloadFailure == nil)
        #expect(Self.marker(in: root) == nil)
    }

    /// The view as the sidebar draws it with a refused save, light and dark side by side, in
    /// `.build/custom-view-reload-marker.png` of the package (a fleet step returns it with `--artifact`).
    @Test func thePictureInLightAndDark() throws {
        func render(_ name: NSAppearance.Name) throws -> CGImage {
            let dark = name == .darkAqua
            // The room's theme draws the rows, as in the app (an appearance alone keeps the app theme).
            let scope = ThemeScope(level: .room)
            let input = dark
                ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
                : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
            scope.setOverride(ThemeSpec("Neutral"), input: input, animated: false)
            let model = Self.drawnList()
            model.reloadFailure = Self.reason
            let (window, root) = Self.host(model)
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: name)
            root.appearance = NSAppearance(named: name)
            scope.root(root)
            root.layoutSubtreeIfNeeded()
            let height = max(40, root.subviews.first.map { ($0 as? AppSceneNativeView)?.preferredHeight(width: 260) ?? 0 } ?? 0) + 16
            root.frame = NSRect(x: 0, y: 0, width: 260, height: height)
            root.layoutSubtreeIfNeeded()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                scope.perform { Palette.pageBackground }.setFill()
                root.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                root.cacheDisplay(in: root.bounds, to: rep)
            }
            return try #require(rep.cgImage)
        }
        let light = try render(.aqua), dark = try render(.darkAqua)
        let gap = 24
        let ctx = try #require(CGContext(data: nil, width: light.width + gap + dark.width, height: max(light.height, dark.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(light, in: CGRect(x: 0, y: ctx.height - light.height, width: light.width, height: light.height))
        ctx.draw(dark, in: CGRect(x: light.width + gap, y: ctx.height - dark.height, width: dark.width, height: dark.height))
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/custom-view-reload-marker.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
