import AppKit
import CmuxNextDevices
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxScreenKit
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// The `macScreen.viewerLook` gallery (Leo 2026-11-21: "our screen shared screen looks like ass"): the real
/// `MacScreenPaneView` drawn offscreen with no session or network, in every viewer look, in every state the pane
/// shows, light and dark (Soft Blue), wide (1280x800) and, in dark, narrow (520x700). The pane is driven through its
/// models (`MacScreenSession.showPreviewState`, the hub phase); the remote frame is a synthetic desktop image laid
/// in the video view, letterboxed by the pane's own fit. Written as PNGs under `mac-screen-viewer-gallery/` in the
/// package, one `<look>-all.png` contact sheet per look, and bundled to `mac-screen-viewer-gallery.tar`. Runs only
/// with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AAMacScreenViewerGalleryTests {
    struct State {
        let name: String
        let scope: SessionScope
        let phase: MacScreenSession.Phase
        var cause: MacScreenSession.FailureCause?
        var linkConnected = false
        var hasFrame = false
        var capturesKeyboard = false
    }

    static let states: [State] = [
        State(name: "connecting", scope: .full, phase: .connecting),
        State(name: "live", scope: .full, phase: .connected, hasFrame: true),
        State(name: "live-view-only", scope: .view, phase: .connected, hasFrame: true),
        State(name: "live-control", scope: .full, phase: .connected, hasFrame: true, capturesKeyboard: true),
        State(name: "no-picture", scope: .view, phase: .failed(message: "", needsSignIn: false), linkConnected: true),
        State(name: "host-asleep", scope: .view, phase: .failed(message: "", needsSignIn: false),
              cause: .host("the display is asleep or the screen is locked")),
        State(name: "error-long", scope: .full, phase: .failed(message: "", needsSignIn: false),
              cause: .link("no route to host after 6 attempts: the relay at turn.example.com:3478 refused the credentials, the direct path timed out and "
                  + "the tailnet address did not answer. Check that the other Mac is awake, signed in to cmux and on a network.")),
    ]

    static let wide = CGSize(width: 1280, height: 800)
    static let narrow = CGSize(width: 520, height: 700)
    /// The remote display's pixels (16:10), so the picture letterboxes in the 1280x800 pane's area below the toolbar.
    static let remotePixels = CGSize(width: 2560, height: 1600)

    /// A plausible remote desktop: wallpaper gradient, menu bar, two windows and a Dock.
    static func desktop() -> NSImage {
        let size = remotePixels
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.12, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.55, green: 0.22, blue: 0.62, alpha: 1),
                                NSColor(srgbRed: 0.98, green: 0.52, blue: 0.36, alpha: 1)])?.draw(in: rect, angle: 35)
            func panel(_ frame: CGRect, _ fill: NSColor, radius: CGFloat = 24) {
                fill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            panel(CGRect(x: 0, y: rect.height - 48, width: rect.width, height: 48), NSColor(white: 1, alpha: 0.25), radius: 0)
            for index in 0 ..< 6 { panel(CGRect(x: 24 + CGFloat(index) * 96, y: rect.height - 34, width: 64, height: 20), NSColor(white: 1, alpha: 0.7), radius: 10) }
            panel(CGRect(x: 220, y: 560, width: 1200, height: 800), NSColor(white: 0.97, alpha: 1))
            panel(CGRect(x: 220, y: 1260, width: 1200, height: 100), NSColor(white: 0.88, alpha: 1), radius: 24)
            panel(CGRect(x: 260, y: 600, width: 320, height: 620), NSColor(white: 0.92, alpha: 1), radius: 16)
            panel(CGRect(x: 1000, y: 180, width: 1180, height: 760), NSColor(white: 0.09, alpha: 0.94))
            for line in 0 ..< 9 { panel(CGRect(x: 1048, y: 860 - CGFloat(line) * 72, width: 300 + CGFloat((line * 137) % 600), height: 24), NSColor(srgbRed: 0.4, green: 0.9, blue: 0.5, alpha: 0.85), radius: 8) }
            panel(CGRect(x: 760, y: 24, width: 1040, height: 128), NSColor(white: 1, alpha: 0.28), radius: 40)
            for index in 0 ..< 9 {
                panel(CGRect(x: 800 + CGFloat(index) * 108, y: 44, width: 88, height: 88),
                      NSColor(hue: CGFloat(index) / 9, saturation: 0.6, brightness: 0.95, alpha: 1), radius: 20)
            }
            return true
        }
    }

    static func render(look: MacScreenViewerLook, state: State, size: CGSize, theme: String, dark: Bool) async throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.phase = .streaming(sessionID: "gallery-session", scope: state.scope)
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio MacBook Pro", preferences: ScreenPreferences())
        defer { pane.close() }
        pane.model.viewerLook = look
        pane.model.hasFrame = state.hasFrame
        pane.model.capturesKeyboard = state.capturesKeyboard
        pane.session?.showPreviewState(phase: state.phase, failureCause: state.cause, linkConnected: state.linkConnected,
                                       frameSize: state.hasFrame ? remotePixels : .zero)
        pane.view.frame = root.bounds
        pane.view.autoresizingMask = [.width, .height]
        root.addSubview(pane.view)
        window.orderFrontRegardless()
        // The toolbar and the card follow the models through Observation (main-actor tasks): let them run.
        for _ in 0 ..< 100 { await Task.yield() }
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        if state.hasFrame {
            // The pane's first subview is its video view; the synthetic frame fills it, so the pane's own fit letterboxes it.
            let video = try #require(pane.view.subviews.first)
            let picture = NSImageView(image: desktop())
            picture.imageScaling = .scaleAxesIndependently
            picture.frame = video.bounds
            picture.autoresizingMask = [.width, .height]
            video.addSubview(picture)
        }
        pane.view.chrome.toolbar.resolveColors()
        pane.view.chrome.card.resolveColors()
        pane.view.chrome.statusStrip?.bar.resolveColors()
        pane.view.chrome.statusStrip?.body.resolveColors()
        for _ in 0 ..< 20 { await Task.yield() }
        pane.view.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Wide light and dark for every state on one sheet (half size, light left, dark right).
    static func sheet(_ images: [(light: CGImage, dark: CGImage)]) throws -> CGImage {
        let cellWidth = Int(wide.width) / 2, cellHeight = Int(wide.height) / 2, gap = 16
        let ctx = try #require(CGContext(data: nil, width: 2 * cellWidth + gap, height: images.count * (cellHeight + gap) - gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for (row, pair) in images.enumerated() {
            let y = ctx.height - (row + 1) * cellHeight - row * gap
            ctx.draw(pair.light, in: CGRect(x: 0, y: y, width: cellWidth, height: cellHeight))
            ctx.draw(pair.dark, in: CGRect(x: cellWidth + gap, y: y, width: cellWidth, height: cellHeight))
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-viewer-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in MacScreenViewerLook.allCases {
            var pairs: [(light: CGImage, dark: CGImage)] = []
            for state in Self.states {
                var pair: [CGImage] = []
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try await Self.render(look: look, state: state, size: Self.wide, theme: theme, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(state.name)-\(mode).png"))
                    pair.append(image)
                }
                pairs.append((pair[0], pair[1]))
                let narrow = try await Self.render(look: look, state: state, size: Self.narrow, theme: "Soft Blue", dark: true)
                try AAGroupHeaderDensityGalleryTests.write(narrow, to: out.appending(path: "\(look.rawValue)-\(state.name)-narrow-dark.png"))
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(pairs), to: out.appending(path: "\(look.rawValue)-all.png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-viewer-gallery.tar", "mac-screen-viewer-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
