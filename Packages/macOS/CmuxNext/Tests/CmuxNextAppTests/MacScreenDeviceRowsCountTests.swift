import AppKit
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

/// Your Devices draws the rows in view, not the whole list (Leo 2026-11-18: "we draw the visible area, right?"):
/// rows alive stay near one viewport and its overscan at 100 devices as at 10,000, one device's change makes one
/// row again, and a scroll step makes only the rows it reveals. Counted on the view tree (the row views alive and
/// the ones not alive before an event), so the same test reads the page before and after windowing.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenDeviceRowsCountTests {
    static let viewport = NSSize(width: 900, height: 640)

    static func devices(_ count: Int, renamed: Int? = nil) -> [MacScreenHomeSnapshot.Device] {
        (0..<count).map { index in
            .init(id: "mac-\(index)", name: index == renamed ? "Mac \(index) renamed" : "Mac \(index)", isPhone: false,
                  online: true, macScreenShared: true, access: MacScreenAccess(.full))
        }
    }

    private func page(_ count: Int) -> (NSWindow, MacScreenHomeView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.viewport), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
        home.frame = window.contentView?.bounds ?? .zero
        home.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(home)
        home.build(MacScreenHomeSnapshot(devices: .list(Self.devices(count)), sharingLook: .list))
        settle(home)
        return (window, home)
    }

    private func settle(_ home: MacScreenHomeView) {
        home.layoutPage()
        home.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func views(under root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(under: $0) }
    }

    private func rows(_ home: MacScreenHomeView) -> [MacScreenRowView] {
        views(under: home).compactMap { $0 as? MacScreenRowView }
    }

    private func made(_ home: MacScreenHomeView, since before: [MacScreenRowView]) -> Int {
        let old = Set(before.map(ObjectIdentifier.init))
        return rows(home).filter { !old.contains(ObjectIdentifier($0)) }.count
    }

    /// The most rows one viewport and one more on each side can hold.
    private func bound(rowHeight: CGFloat) -> Int {
        3 * Int(ceil(Self.viewport.height / max(1, rowHeight))) + 4
    }

    @Test(arguments: [100, 10_000])
    func mountedRowsStayNearTheViewport(count: Int) throws {
        let (window, home) = page(count)
        defer { window.close() }
        let alive = rows(home)
        let height = try #require(alive.first?.frame.height)
        print("mac-screen-rows n=\(count) alive=\(alive.count) rowHeight=\(height) bound=\(bound(rowHeight: height))")
        #expect(alive.count <= bound(rowHeight: height))
        // The page still scrolls over every device: the document holds all their heights.
        let document = try #require(views(under: home).compactMap { $0 as? NSScrollView }.first?.documentView)
        #expect(document.frame.height >= CGFloat(count) * height)
    }

    @Test(arguments: [100, 10_000])
    func oneDeviceChangeMakesOneRow(count: Int) {
        let (window, home) = page(count)
        defer { window.close() }
        let before = rows(home)
        home.build(MacScreenHomeSnapshot(devices: .list(Self.devices(count, renamed: 3)), sharingLook: .list))
        settle(home)
        let remade = made(home, since: before)
        print("mac-screen-rows n=\(count) oneChangeMade=\(remade)")
        #expect(remade == 1)
        #expect(views(under: home).contains { $0.accessibilityIdentifier() == "macScreen.home.name.Mac 3 renamed" })
    }

    @Test(arguments: [100, 10_000])
    func aScrollStepMakesOnlyTheRowsItReveals(count: Int) throws {
        let (window, home) = page(count)
        defer { window.close() }
        let scroll = try #require(views(under: home).compactMap { $0 as? NSScrollView }.first)
        let height = try #require(rows(home).first?.frame.height)
        let step = 3 * height
        let before = rows(home)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: step))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(home)
        let remade = made(home, since: before)
        print("mac-screen-rows n=\(count) scrollStepMade=\(remade)")
        #expect(remade <= 4)
        // Scrolled to the end, the last device is there to see.
        let end = try #require(scroll.documentView).frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(home)
        #expect(views(under: home).contains { $0.accessibilityIdentifier() == "macScreen.home.name.Mac \(count - 1)" })
        #expect(rows(home).count <= bound(rowHeight: height))
    }
}
