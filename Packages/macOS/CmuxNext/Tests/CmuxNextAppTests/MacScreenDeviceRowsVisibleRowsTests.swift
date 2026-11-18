import AppKit
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import QuartzCore
import Testing

/// Screen Sharing's Your Devices under the visible-rows contract (`VisibleRowsContract`), at 100 and 10,000 devices.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct MacScreenDeviceRowsVisibleRowsTests {
    @Test func yourDevices() async throws {
        try await VisibleRowsContract.check(MacScreenYourDevicesRows.self)
    }
}

/// The home page over `rows` online, shared Macs in a 660 x 640 window (narrow enough that a width step reaches the
/// column, which caps at 620).
@MainActor final class MacScreenYourDevicesRows: VisibleRowsFixture {
    static let name = "screen sharing devices"
    static let size = NSSize(width: 660, height: 640)
    let home: MacScreenHomeView
    let window: NSWindow
    let count: Int
    let list: MacScreenDeviceRows
    let scroll: NSScrollView

    init(rows: Int) async throws {
        _ = NSApplication.shared
        count = rows
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: Self.size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
        home.frame = NSRect(origin: .zero, size: Self.size)
        home.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(home)
        window.orderFrontRegardless()
        home.build(MacScreenHomeSnapshot(devices: .list(Self.devices(rows, renamed: nil)), sharingLook: .list))
        list = try #require(home.deviceRows)
        scroll = try #require(list.enclosingScrollView)
        drawFrame()
    }

    static func devices(_ count: Int, renamed: Int?) -> [MacScreenHomeSnapshot.Device] {
        (0..<count).map { index in
            .init(id: "vr-\(index)", name: index == renamed ? "Mac \(index) renamed" : "Mac \(index)", isPhone: false,
                  online: true, macScreenShared: true, access: MacScreenAccess(.full))
        }
    }

    private func drawFrame() {
        home.layoutPage()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let visible = list.convert(scroll.contentView.bounds, from: scroll.contentView)
        return list.subviews.filter { visible.intersects($0.frame) }.count
    }

    /// A shown Mac is renamed (the hub's device list changed), as the page's snapshot redraws it.
    func changeOneItem() async throws {
        home.build(MacScreenHomeSnapshot(devices: .list(Self.devices(count, renamed: 2)), sharingLook: .list))
        drawFrame()
    }

    /// From the middle of the page (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        guard maxY > 0, let row = list.subviews.first?.frame.height else { return false }
        move(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        move(to: clip.bounds.minY + row)
        return true
    }

    private func move(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        drawFrame()
    }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: Self.size.width - 8, height: Self.size.height))
        drawFrame()
        return true
    }

    func close() { window.close() }
}
