@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Testing

/// Follow mode's focus signals: the Mac's pointer, caret, focused window and
/// screen damage, in the captured display's pixels, one JSON event per
/// message on the viewer's `focus` channel (the cmux-follow-cam `Event`).
struct FocusSignalsTests {
    // MARK: The producer

    /// A probe with no Accessibility grant: no caret, but the pointer and the
    /// window (CGWindowList needs no grant).
    final class FakeProbe: FocusProbe, @unchecked Sendable {
        let lock = NSLock()
        var pointerAt: CGPoint? = CGPoint(x: 100, y: 100)
        var window: FocusWindow? = FocusWindow(id: 5, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var caretAt: CGRect?
        func pointer() -> CGPoint? { lock.withLock { pointerAt } }
        func focusedWindow() -> FocusWindow? { lock.withLock { window } }
        func caret() -> CGRect? { lock.withLock { caretAt } }
    }

    final class Sent: @unchecked Sendable {
        let lock = NSLock()
        var messages: [String] = []
        var open = true
        func send(_ text: String) -> Bool { lock.withLock { open ? (messages.append(text), true).1 : false } }
        var kinds: [String] {
            lock.withLock { messages }.compactMap { text in
                (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["kind"] as? String
            }
        }
        func take() -> [String] { lock.withLock { defer { messages.removeAll() }; return messages } }
    }

    func makeProducer(_ probe: FakeProbe, _ sent: Sent) -> FocusSignalProducer {
        let geometry = FocusGeometry(display: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixels: CGSize(width: 3456, height: 2234))
        return FocusSignalProducer(probe: probe, geometry: { geometry }, send: { sent.send($0) })
    }

    /// Without the rules (cmux-rd-screen `FocusProducer`, with their tests) nothing is sent.
    @Test func withoutTheRulesNothingIsSent() {
        let probe = FakeProbe(), sent = Sent()
        let producer = makeProducer(probe, sent)
        producer.damage([CGRect(x: 0, y: 0, width: 10, height: 10)], captured: CGSize(width: 100, height: 100))
        for tick in 0 ..< 40 { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.kinds.isEmpty)
    }

    @Test func noGeometryMeansNothingIsSent() {
        let probe = FakeProbe(), sent = Sent()
        let producer = FocusSignalProducer(probe: probe, geometry: { nil }, send: { sent.send($0) })
        for tick in 0 ..< 40 { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.kinds.isEmpty)
    }

    // MARK: The channel

    @Test func focusIsAnExtraChannelNeverThePrimary() {
        #expect(VNCPeerLink.extraLabels.contains(VNCPeerLink.focusLabel))
        #expect(VNCPeerLink.extraLabels.contains("pointer"))
        #expect(!VNCPeerLink.extraLabels.contains("input"))
        #expect(VNCPeerLink.focusLabel == "focus")
    }
}

#if os(macOS)
/// The caret is never read out of a password field: where someone types a
/// password is not sent to the viewer.
@Suite struct FocusSecureFieldTests {
    @Test func passwordFieldsAreSecure() {
        #expect(SystemFocusProbe.isSecureTextField(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(SystemFocusProbe.isSecureTextField(role: "AXSecureTextField", subrole: nil))
    }

    @Test func ordinaryTextIsNotSecure() {
        #expect(!SystemFocusProbe.isSecureTextField(role: "AXTextField", subrole: nil))
        #expect(!SystemFocusProbe.isSecureTextField(role: "AXTextArea", subrole: "AXSearchField"))
        #expect(!SystemFocusProbe.isSecureTextField(role: nil, subrole: nil))
    }
}
#endif
