import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The SwiftUI panels' toasts (`cmuxToast`, Feed and Tasks rejects): every end of the toast
/// clears the model, so the same reject shows again, and a panel that goes away does not keep an
/// old reject to replay when it reopens.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastModifierTests {
    private final class Model {
        var reject: String? = "Refused"
        var cleared = 0
    }

    private static func anchor(_ model: Model, center: CmuxToastCenter, in window: NSWindow) -> CmuxToastAnchorView {
        let view = CmuxToastAnchorView()
        view.center = center
        window.contentView?.addSubview(view)
        view.request = CmuxToastAnchorView.Request(id: "feed.reject", message: model.reject, duration: .seconds(30)) {
            model.reject = nil
            model.cleared += 1
        }
        return view
    }

    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    private static func settle(until done: () -> Bool) async throws {
        for _ in 0..<40 where !done() { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// Three newer toasts push the reject out of the stack: the model still hears it ended.
    @Test func aRejectPushedOutOfTheStackClearsTheModel() async throws {
        let center = CmuxToastCenter(host: HeadlessHost())
        let window = Self.window()
        defer { window.closeAfterTest() }
        let model = Model()
        _ = Self.anchor(model, center: center, in: window)
        #expect(center.toasts(in: window).map(\.id) == ["feed.reject"])
        for index in 0..<3 { center.show(CmuxToast(id: "other.\(index)", message: "Other \(index)"), in: window) }
        #expect(!center.toasts(in: window).map(\.id).contains("feed.reject"))
        try await Self.settle { model.cleared > 0 }
        #expect(model.cleared == 1)
        #expect(model.reject == nil)
    }

    /// The panel closes while its reject shows: the model is cleared, so reopening it shows nothing.
    @Test func aClosedPanelClearsItsReject() async throws {
        let center = CmuxToastCenter(host: HeadlessHost())
        let window = Self.window()
        defer { window.closeAfterTest() }
        let model = Model()
        let view = Self.anchor(model, center: center, in: window)
        view.removeFromSuperview()
        view.dismantle()
        #expect(center.toasts(in: window).isEmpty)
        try await Self.settle { model.cleared > 0 }
        #expect(model.reject == nil)
    }
}

@MainActor
private final class HeadlessHost: CmuxToastHosting {
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
