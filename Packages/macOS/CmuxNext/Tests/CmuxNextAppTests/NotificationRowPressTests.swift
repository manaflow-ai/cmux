import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Lawrence 2026-10-19: "mouse down to immediately open". A row of the notifications panel opens its
/// notification on the press, once; the release opens nothing more.
@MainActor @Suite(.serialized) struct NotificationRowPressTests {
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view: NotificationRowView
        private(set) var opened = 0

        init(source: String? = "terminal") {
            let row = NotificationsPanelRow(id: "n1", title: "Build finished", subtitle: nil, body: "All green", level: .info,
                                            source: source, workspaceTitle: "cmux", createdAt: Date(timeIntervalSince1970: 0), unread: true,
                                            surface: nil, terminal: nil)
            var open: () -> Void = {}
            view = NotificationRowView(row: row, now: Date(timeIntervalSince1970: 60),
                                       callbacks: .init(open: { open() }, dismiss: {}, menu: { NSMenu() }))
            open = { [unowned self] in opened += 1 }
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
            window.contentView = view
            window.orderFrontRegardless()
        }

        func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let center = view.convert(NSPoint(x: 40, y: view.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                   pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    @Test func aNotificationRowOpensOnThePressAndOnlyOnce() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        harness.view.mouseDown(with: try harness.event(.leftMouseDown))
        #expect(harness.opened == 1, "the press did not open the notification")
        harness.view.mouseUp(with: try harness.event(.leftMouseUp))
        #expect(harness.opened == 1, "the release opened it a second time")
    }

    /// The producer the daemon reported reads before the workspace, in the
    /// row's caption and to VoiceOver.
    @Test func aNotificationRowNamesItsProducer() {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        #expect(harness.view.accessibilityLabel() == "Build finished, Terminal Programs, cmux, All green")
    }

    /// A ledger row from a daemon that does not report a source reads as it
    /// did before: the workspace alone.
    @Test func aRowWithoutAProducerKeepsTheWorkspaceAlone() {
        let harness = Harness(source: nil)
        defer { harness.window.orderOut(nil) }
        #expect(harness.view.accessibilityLabel() == "Build finished, cmux, All green")
    }
}
