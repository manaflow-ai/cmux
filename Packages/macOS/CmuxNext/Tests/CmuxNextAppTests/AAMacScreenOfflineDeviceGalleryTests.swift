import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxTheme
import Foundation
import Testing

/// The Screen Sharing page with an offline Mac, an online Mac whose first connect asks, and the
/// first-use steps: the real page drawn offscreen, light and dark (Soft Blue). Written as PNGs under
/// `mac-screen-offline-gallery/` in the package and bundled to `mac-screen-offline-gallery.tar` for
/// `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenOfflineDeviceGalleryTests {
    static let devices: [MacScreenHomeSnapshot.Device] = [
        .init(id: "dev-work-mac", name: "Work Mac", isPhone: false, online: false, macScreenShared: true,
              access: MacScreenAccess(.ask)),
        .init(id: "dev-studio", name: "Studio", isPhone: false, online: true, macScreenShared: true,
              access: MacScreenAccess(.ask)),
    ]
    static let sharing = MacScreenHomeSnapshot.Sharing(isSharing: false, busy: false, screenRecordingGranted: true,
                                                        accessibilityGranted: true, showFirstUse: true)

    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 720, height: CGFloat = 520
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
        home.build(MacScreenHomeSnapshot(devices: .list(devices), sharing: sharing, sharingLook: .list))
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-offline-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
            let image = try Self.render(theme: theme, dark: dark)
            let url = out.appending(path: "offline-device-\(mode).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-offline-gallery.tar", "mac-screen-offline-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
