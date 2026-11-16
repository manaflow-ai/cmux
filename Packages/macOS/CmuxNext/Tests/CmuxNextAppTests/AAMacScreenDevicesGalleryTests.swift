import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxTheme
import Foundation
import Testing

/// The Screen Sharing page Leo saw (2026-11-15), redrawn: Laptop online and sharing, Mini
/// online with sharing off, Work Mac offline, This Mac sharing with a permission missing or a device
/// connected. Every `macScreen.devicesLook` at the page's width and at a narrow one (no text cut off), light
/// and dark (Soft Blue). Written as PNGs under `mac-screen-devices-gallery/` in the package and bundled to
/// `mac-screen-devices-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenDevicesGalleryTests {
    static let devices: [MacScreenHomeSnapshot.Device] = [
        .init(id: "dev-laptop", name: "Laptop", online: true, macScreenShared: true, access: MacScreenAccess(.ask)),
        .init(id: "dev-mini", name: "Mini", online: true, macScreenShared: false, access: MacScreenAccess(.ask)),
        .init(id: "dev-work-mac", name: "Work Mac", online: false, macScreenShared: true, access: MacScreenAccess(.ask),
              lastSeen: Date().addingTimeInterval(-2 * 3600)),
    ]
    static let states: [(name: String, sharing: MacScreenHomeSnapshot.Sharing)] = [
        ("grant", .init(isSharing: true, busy: false, screenRecordingGranted: false, accessibilityGranted: false)),
        ("connected", .init(isSharing: true, busy: false, screenRecordingGranted: true, accessibilityGranted: true,
                            session: .init(id: "s1", viewerID: "v1", viewerName: "Laptop", scope: .full, connected: true))),
        ("off", .init(isSharing: false, busy: false, screenRecordingGranted: true, accessibilityGranted: true)),
    ]

    static func render(look: MacScreenDevicesLook, sharing: MacScreenHomeSnapshot.Sharing, width: CGFloat,
                       theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let height: CGFloat = 760
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
        home.build(MacScreenHomeSnapshot(devices: .list(devices), sharing: sharing, keyboard: .init(enabled: false, needsAccessibility: false),
                                         sharingLook: .simple, devicesLook: look))
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-devices-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in MacScreenDevicesLook.allCases {
            for state in Self.states {
                for (size, width) in [("wide", CGFloat(720)), ("narrow", CGFloat(460))] {
                    for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                        // The narrow width is drawn in light only: it proves wrapping, not color.
                        if size == "narrow", dark { continue }
                        let image = try Self.render(look: look, sharing: state.sharing, width: width, theme: theme, dark: dark)
                        let url = out.appending(path: "\(look.rawValue)-\(state.name)-\(size)-\(mode).png")
                        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                        CGImageDestinationAddImage(dest, image, nil)
                        #expect(CGImageDestinationFinalize(dest))
                    }
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "mac-screen-devices-gallery.tar", "mac-screen-devices-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
