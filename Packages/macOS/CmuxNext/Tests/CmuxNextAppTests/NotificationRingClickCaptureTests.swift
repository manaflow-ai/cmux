import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing
import UniformTypeIdentifiers

/// The picture of the report (Lawrence, 2026-10-31: "i click a terminal that has notif and it doesnt
/// dismiss it"): a remote group's terminal with an unread notification, before and after a click in
/// its pane, side by side in `.build/notification-ring-click.png` (a fleet step returns it with
/// `--artifact`). It asserts only that both drew, so it runs on the base too: there the ring stays
/// after the click; NotificationRingEdgeCaseTests checks the read.
@MainActor
@Suite(.serialized)
struct NotificationRingClickCaptureTests {
    private static func snapshot(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let scale = 2, width = Int(view.bounds.width) * scale, height = Int(view.bounds.height) * scale
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Running animations do not render offscreen: the ring's model values (at rest) do.
        try #require(view.layer).render(in: ctx)
        return try #require(ctx.makeImage())
    }

    @Test func aClickInARemoteTerminalBeforeAndAfter() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { false }, heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.notifications.leftButtonIsDown = { true }
        let host = try SSHHost(destination: SSHDestination(parsing: "lawrence@cmux-lawrence.tail1.ts.net")).named("cmux-lawrence")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-ring-capture-unused")),
                                    environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        services.machines.add(ssh)
        let store = ssh.daemon.store
        // The remote daemon's tree, unread, and as it echoes once a read reaches it.
        func tree(unread: Bool) -> DaemonTree {
            let marker = TabNotification(notification: NotificationID(rawValue: 9), unread: unread, level: .info, source: "terminal")
            let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_remote", title: "claude", notification: marker)])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "remote-capture"), name: "cmux-lawrence",
                                                             screens: [screen])])
        }
        store.apply(snapshot: tree(unread: true))
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"remote-capture","generation":"g1","capabilities":["state-resources-v1","notification-ack-v1"]}"#.utf8))
        store.noteHandshake(identity)
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id], frame: CGRect(x: 200, y: 200, width: 640, height: 400)))
        let window = try #require(controller.window)
        defer { controller.teardown(); window.close() }
        try await PinnedPageTests.until({ controller.content?.panes.isEmpty == false })
        let content = try #require(controller.content)
        content.contentView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(2))  // the ring's arrival settles to rest
        let view = try #require(window.contentView)
        let before = try Self.snapshot(view)
        let root = content.layoutView
        let frame = try #require(content.layoutModel.visiblePanes.first.flatMap { root.frame(of: $0) })
        services.notifications.noteMouseDown(in: window, at: root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
        // No daemon runs here: when the click sent the read, apply the tree the daemon would echo.
        if services.notifications.log.contains(where: { $0.hasPrefix("ack ") }) { store.apply(snapshot: tree(unread: false)) }
        try await Task.sleep(for: .seconds(2))  // the dismiss flash ends
        let after = try Self.snapshot(view)
        let note = "unread after the click: \(tab.hasUnread)"
        let gap = 24
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: before.width + after.width + gap, height: max(before.height, after.height),
                                         bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
        ctx.draw(after, in: CGRect(x: before.width + gap, y: 0, width: after.width, height: after.height))
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/notification-ring-click.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made: CGImageDestination? = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
        let dest = try #require(made)
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest), "\(note)")
        try Data(note.utf8).write(to: package.appendingPathComponent(".build/notification-ring-click.txt"))
    }
}
