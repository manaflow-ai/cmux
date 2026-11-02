import AppKit
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// u3849 follow-up: pairing leaves the menu bar. Add Server is a floating glass card over the
/// cmux-next window, near the top center, on every Space and over full screen, that never takes
/// the keys from what the user types unless the user asked for it (palette or Settings).
/// A found server's card answers Approve (Return) or Deny (Escape).
@MainActor @Suite(.serialized, .closesItsWindows) struct AddServerCardTests {
    init() { _ = NSApplication.shared }

    private func model() -> (MockServerSource, ServerModel) {
        let source = MockServerSource(scenario: .healthyMac)
        source.echoImmediately = false
        let model = ServerModel(source: source)
        model.start()
        return (source, model)
    }

    @Test func theCardFloatsOnEverySpaceAndOverFullScreenWithoutActivating() {
        let card = AddServerCardPanel(model: model().1)
        defer { card.closeAfterTest() }
        #expect(card.styleMask.contains(.nonactivatingPanel))
        #expect(card.styleMask.contains(.borderless))
        #expect(card.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(card.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(card.level.rawValue >= NSWindow.Level.floating.rawValue)
        #expect(card.hidesOnDeactivate == false)
        #expect(card.isOpaque == false)
    }

    @Test func itSitsNearTheTopCenterOfTheWindow() {
        let parent = NSRect(x: 100, y: 100, width: 1200, height: 800)
        let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = AddServerCardPanel.placement(size: CGSize(width: 400, height: 300), over: parent, in: visible)
        #expect(frame.midX == parent.midX)
        #expect(frame.maxY == parent.maxY - AddServerCardPanel.topInset)
        #expect(frame.size == CGSize(width: 400, height: 300))
    }

    @Test func itStaysOnScreenAndFallsBackToTheScreenTop() {
        let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        // A window hanging off the left edge: the card slides back onto the screen.
        let clamped = AddServerCardPanel.placement(size: CGSize(width: 400, height: 300),
                                                   over: NSRect(x: -900, y: 200, width: 1000, height: 700), in: visible)
        #expect(clamped.minX == visible.minX)
        // No window: the top center of the screen.
        let none = AddServerCardPanel.placement(size: CGSize(width: 400, height: 300), over: nil, in: visible)
        #expect(none.midX == visible.midX)
        #expect(none.maxY == visible.maxY - AddServerCardPanel.topInset)
    }

    @Test func anArrivingRequestDoesNotTakeTheKeys() {
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        parent.makeKeyAndOrderFront(nil)
        let card = AddServerCardPanel(model: model().1)
        defer { card.close() }
        card.present(over: parent, takeKeys: false)
        #expect(card.isVisible)
        #expect(!card.isKeyWindow)
        #expect(NSApp.keyWindow !== card)
    }

    @Test func aFoundServerIsApprovedOrDenied() throws {
        let (_, model) = model()
        #expect(ServerStrings.escapeTitle(model.addServerStep) == ServerStrings.cancel)
        model.setApprovalCode(MockServerScenario.offerCode)
        model.handle(.candidate(MockServerScenario.candidate))
        let key = try #require(model.pending.last?.key)
        model.handle(.settled(key: key, reject: nil))
        #expect(ServerStrings.escapeTitle(model.addServerStep) == ServerStrings.deny)
        #expect(ServerStrings.returnTitle(model.addServerStep) == ServerStrings.approve)
    }
}
