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

    static func render(_ target: RemoteConnectionTarget, layout: RemoteViewUnavailableView.Layout, theme: String,
                       dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 720, height: CGFloat = 360
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
        let card = RemoteViewUnavailableView(content: .confirmTarget(target), layout: layout)
        card.frame = root.bounds
        card.autoresizingMask = [.width, .height]
        root.addSubview(card)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "remote-connect-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for layout in RemoteViewUnavailableView.Layout.allCases {
            for (name, target) in Self.targets {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(target, layout: layout, theme: theme, dark: dark)
                    let url = out.appending(path: "\(layout.rawValue)-\(name)-\(mode).png")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
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
