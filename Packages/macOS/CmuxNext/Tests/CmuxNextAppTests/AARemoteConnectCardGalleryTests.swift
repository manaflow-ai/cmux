import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextRemoteView
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The remote desktop Connect card (`RemoteViewUnavailableView`, the tab another action opened):
/// the real view drawn offscreen in Soft Blue light and dark, for a start-chat machine (no human
/// name: "Cloud machine") and a named one. Written as PNGs under `remote-connect-card-gallery/` in
/// the package and bundled to `remote-connect-card-gallery.tar` for `cmux-ci run --artifact`.
/// Runs only with `CMUX_TEST_REQUIRE_GUI=1`. Leo, 2026-11-16: "is is a weirdly styled thing :(".
@MainActor @Suite(.serialized, .closesItsWindows) struct AARemoteConnectCardGalleryTests {
    static let targets: [(String, RemoteConnectionTarget)] = [
        ("chat-machine", .desktop(name: "", status: "Running", region: "us-west", isLive: true)),
        ("named-paused", .desktop(name: "Build box", status: "Paused", region: "eu-central")),
    ]

    static func render(_ target: RemoteConnectionTarget, theme: String, dark: Bool, width: CGFloat = 720) async throws -> CGImage {
        _ = NSApplication.shared
        let height: CGFloat = 320
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.contentBackground.withAlphaComponent(1) }.cgColor
        let card = RemoteViewUnavailableView(content: .confirmTarget(target))
        card.frame = root.bounds
        card.autoresizingMask = [.width, .height]
        root.addSubview(card)
        window.orderFrontRegardless()
        // Twice: the text learns its width in the first pass and asks for its wrapped height in the second.
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        // The window server's composited image, as on screen: `cacheDisplay` misses layer-drawn
        // content (ChromeLabel draws its text into its layer), which came back blank on some workers.
        // The first composited frame can arrive a little after orderFront: settle briefly.
        var image: CGImage?
        for _ in 0..<20 where image == nil {
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(50))
            image = try? await window.screenshotImage()
        }
        window.close()
        let shot = try #require(image)
        #expect(!shot.isFullyTransparent)
        return shot
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "remote-connect-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Every target in light and dark at a roomy pane width, and the chat machine in a narrow pane (the text wraps).
        var shots: [(String, RemoteConnectionTarget, String, Bool, CGFloat)] = []
        for (name, target) in Self.targets {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                shots.append(("\(name)-\(mode)", target, theme, dark, 720))
            }
        }
        shots.append(("chat-machine-narrow-dark", Self.targets[0].1, "Soft Blue", true, 380))
        for (file, target, theme, dark, width) in shots {
            let image = try await Self.render(target, theme: theme, dark: dark, width: width)
            let url = out.appending(path: "connect-card-\(file).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "remote-connect-card-gallery.tar", "remote-connect-card-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
