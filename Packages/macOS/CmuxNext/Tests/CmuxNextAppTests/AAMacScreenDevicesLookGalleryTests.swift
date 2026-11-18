import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxTheme
import Foundation
import Testing

/// The `macScreen.devicesLook` gallery (Leo 2026-11-16 on Settings > Screen Sharing: "this needs to shut up"):
/// the real page drawn offscreen, light and dark (Soft Blue). `before` is the classic look over the records as
/// the hub listed them (one Mac registered twice, three times); every other image is a look over one entry per
/// Mac. Written as PNGs under `mac-screen-devices-gallery/` in the package and bundled to
/// `mac-screen-devices-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenDevicesLookGalleryTests {
    static func device(_ id: String, _ name: String, online: Bool, shared: Bool = true,
                       access: MacScreenAccess = MacScreenAccess(.ask)) -> MacScreenHomeSnapshot.Device {
        .init(id: id, name: name, isPhone: false, online: online, macScreenShared: shared, access: access)
    }

    /// The records before `DeviceList`: this Mac's other build as an offline remote, two Macs twice.
    static let records: [MacScreenHomeSnapshot.Device] = [
        device("this-dev", "Work Mac", online: false),
        device("this-nightly-old", "Work Mac", online: false),
        device("air", "Air", online: true, access: MacScreenAccess(.full)),
        device("office", "Office", online: true, shared: false),
        device("den-a", "Den", online: false),
        device("mini-a", "Office mini (3)", online: false),
        device("den-b", "Den", online: false),
        device("mini-b", "Office mini (3)", online: false),
    ]

    /// One entry per Mac, this Mac's builds gone (what `DeviceHub.otherDevices` lists now).
    static let machines: [MacScreenHomeSnapshot.Device] = [
        device("air", "Air", online: true, access: MacScreenAccess(.full)),
        device("office", "Office", online: true, shared: false),
        device("den-b", "Den", online: false),
        device("mini-b", "Office mini (3)", online: false),
    ]

    static let shots: [(name: String, look: MacScreenDevicesLook, devices: [MacScreenHomeSnapshot.Device], expanded: Bool)] = [
        ("before", .classic, records, false),
        ("quiet", .quiet, machines, false),
        ("quiet-open", .quiet, machines, true),
        ("offline-lines", .offlineLines, machines, false),
        ("online-only", .onlineOnly, machines, false),
    ]

    static func render(_ shot: (name: String, look: MacScreenDevicesLook, devices: [MacScreenHomeSnapshot.Device], expanded: Bool),
                       theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 720, height: CGFloat = shot.look == .classic ? 1040 : 480
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
        let home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
        home.frame = root.bounds
        home.autoresizingMask = [.width, .height]
        root.addSubview(home)
        window.orderFrontRegardless()
        home.resolveColors()
        home.offlineExpanded = shot.expanded
        home.build(MacScreenHomeSnapshot(devices: .list(shot.devices), sharingLook: .list, devicesLook: shot.look))
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
        for shot in Self.shots {
            for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                let image = try Self.render(shot, theme: theme, dark: dark)
                let url = out.appending(path: "\(shot.name)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
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
