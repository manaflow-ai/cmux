import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxTheme
import Foundation
import Testing

/// The `macScreen.sharingLook` gallery (Lawrence 2026-11-07, "improve this ui"): the real Screen Sharing
/// page drawn offscreen in every look, light and dark (Soft Blue), with both permissions allowed, both
/// missing, and a device viewing. Written as PNGs under `mac-screen-sharing-gallery/` in the package and
/// bundled to `mac-screen-sharing-gallery.tar` for `cmux-ci run --artifact`. Runs only with
/// `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenSharingGalleryTests {
    static let states: [(name: String, sharing: MacScreenHomeSnapshot.Sharing)] = [
        ("ready", .init(isSharing: true, busy: false, screenRecordingGranted: true, accessibilityGranted: true, session: nil, lastError: nil)),
        ("missing", .init(isSharing: true, busy: false, screenRecordingGranted: false, accessibilityGranted: false, session: nil, lastError: nil)),
        ("viewing", .init(isSharing: true, busy: false, screenRecordingGranted: true, accessibilityGranted: true,
                          session: .init(id: "s1", viewerID: "v1", viewerName: "Studio", scope: .view, connected: true), lastError: nil)),
        ("off", .init(isSharing: false, busy: false, screenRecordingGranted: true, accessibilityGranted: true, session: nil, lastError: nil)),
    ]

    static func render(look: MacScreenSharingLook, sharing: MacScreenHomeSnapshot.Sharing, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 720, height: CGFloat = 640
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
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let home = MacScreenHomeView(host: MacScreenShareHost(work: BackgroundWork()), actions: MacScreenHomeActions())
        home.frame = root.bounds
        home.autoresizingMask = [.width, .height]
        root.addSubview(home)
        window.orderFrontRegardless()
        home.resolveColors()
        home.build(MacScreenHomeSnapshot(sharing: sharing, keyboard: .init(enabled: false, needsAccessibility: false), sharingLook: look))
        home.layoutPage()
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-sharing-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in MacScreenSharingLook.allCases {
            for state in Self.states {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(look: look, sharing: state.sharing, theme: theme, dark: dark)
                    let url = out.appending(path: "\(look.rawValue)-\(state.name)-\(mode).png")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-sharing-gallery.tar", "mac-screen-sharing-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
