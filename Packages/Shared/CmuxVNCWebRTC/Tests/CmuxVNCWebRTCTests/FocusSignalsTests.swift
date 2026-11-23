@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Testing

/// Follow mode's focus signals: the Mac's pointer, caret, focused window and
/// screen damage, in the captured display's pixels, one JSON event per
/// message on the viewer's `focus` channel (the cmux-follow-cam `Event`).
struct FocusSignalsTests {
    // MARK: Coordinates

    /// A 16" MacBook Pro main display: 1728x1117 points, 3456x2234 pixels.
    let retina = FocusGeometry(display: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixels: CGSize(width: 3456, height: 2234))
    /// A 1x 1920x1080 display to the right of it, its top 100 points above the main display's.
    let second = FocusGeometry(display: CGRect(x: 1728, y: -100, width: 1920, height: 1080), pixels: CGSize(width: 1920, height: 1080))

    @Test func globalPointsBecomeDisplayPixelsAtTheDisplaysScale() {
        #expect(retina.point(CGPoint(x: 10, y: 20)) == CGPoint(x: 20, y: 40))
        #expect(retina.point(CGPoint(x: 864, y: 558.5)) == CGPoint(x: 1728, y: 1117))
        #expect(second.point(CGPoint(x: 1728 + 960, y: -100 + 540)) == CGPoint(x: 960, y: 540))
        #expect(second.point(CGPoint(x: 1728, y: -100)) == CGPoint(x: 0, y: 0), "the second display's top left is its origin")
    }

    @Test func aPointOnAnotherDisplayIsNone() {
        #expect(retina.point(CGPoint(x: 1800, y: 10)) == nil, "on the second display")
        #expect(second.point(CGPoint(x: 100, y: 100)) == nil, "on the main display")
        #expect(retina.point(CGPoint(x: -1, y: 10)) == nil)
    }

    @Test func rectsAreClippedToTheDisplay() {
        #expect(retina.rect(CGRect(x: 100, y: 50, width: 200, height: 10)) == CGRect(x: 200, y: 100, width: 400, height: 20))
        // A window hanging off the right edge onto the second display.
        #expect(retina.rect(CGRect(x: 1628, y: 1000, width: 400, height: 300)) == CGRect(x: 3256, y: 2000, width: 200, height: 234))
        #expect(second.rect(CGRect(x: 1628, y: -200, width: 200, height: 200)) == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(retina.rect(CGRect(x: 2000, y: 10, width: 50, height: 50)) == nil, "wholly on another display")
    }

    @Test func aZeroWidthCaretKeepsItsHeight() {
        #expect(retina.rect(CGRect(x: 100, y: 100, width: 0, height: 16)) == CGRect(x: 200, y: 200, width: 0, height: 32))
    }

    @Test func appKitCoordinatesFlipAroundTheMainDisplay() {
        // AppKit: origin at the main display's bottom left, y up. CG: its top left, y down.
        let main: CGFloat = 1117
        #expect(FocusGeometry.flipped(appKit: CGPoint(x: 10, y: 1117), mainHeight: main) == CGPoint(x: 10, y: 0))
        #expect(FocusGeometry.flipped(appKit: CGRect(x: 10, y: 1000, width: 50, height: 17), mainHeight: main)
            == CGRect(x: 10, y: 100, width: 50, height: 17))
        // The second display's top (AppKit y 1117 + 100) is CG y -100.
        #expect(FocusGeometry.flipped(appKit: CGPoint(x: 1800, y: 1217), mainHeight: main) == CGPoint(x: 1800, y: -100))
        let caret = FocusGeometry.flipped(appKit: CGRect(x: 1828, y: 1197, width: 0, height: 20), mainHeight: main)
        #expect(second.rect(caret) == CGRect(x: 100, y: 0, width: 0, height: 20), "a caret at the second display's top")
        let lower = FocusGeometry.flipped(appKit: CGRect(x: 1828, y: 1117, width: 0, height: 20), mainHeight: main)
        #expect(second.rect(lower) == CGRect(x: 100, y: 80, width: 0, height: 20))
    }

    @Test func damageInTheCapturedPictureScalesToDisplayPixels() {
        // The viewer asked for a 1728-pixel long edge: capture is half the display's pixels.
        let captured = CGSize(width: 1728, height: 1117)
        #expect(retina.captured(CGRect(x: 10, y: 20, width: 30, height: 40), in: captured) == CGRect(x: 20, y: 40, width: 60, height: 80))
        #expect(retina.captured(CGRect(x: 1700, y: 1100, width: 100, height: 100), in: captured)
            == CGRect(x: 3400, y: 2200, width: 56, height: 34), "clipped to the display")
        #expect(retina.captured(CGRect(x: 10, y: 20, width: 30, height: 40), in: .zero) == nil)
    }

    // MARK: Encoding (cmux-follow-cam's serde `Event`: t_us, then the `kind` tag and its fields)

    @Test func eventsEncodeAsTheEnginesJSON() {
        #expect(FocusEvent(tUs: 123, signal: .source(w: 3024, h: 1964)).json == #"{"t_us":123,"kind":"source","w":3024,"h":1964}"#)
        #expect(FocusEvent(tUs: 123, signal: .pointer(x: 10, y: 20.5)).json == #"{"t_us":123,"kind":"pointer","x":10,"y":20.5}"#)
        #expect(FocusEvent(tUs: 7, signal: .caret(CGRect(x: 1, y: 2, width: 0, height: 32))).json
            == #"{"t_us":7,"kind":"caret","x":1,"y":2,"w":0,"h":32}"#)
        #expect(FocusEvent(tUs: 7, signal: .window(id: 42, CGRect(x: 0, y: 50, width: 800, height: 600))).json
            == #"{"t_us":7,"kind":"window","id":42,"x":0,"y":50,"w":800,"h":600}"#)
        #expect(FocusEvent(tUs: 7, signal: .damage(CGRect(x: 1.25, y: 2, width: 3, height: 4))).json
            == #"{"t_us":7,"kind":"damage","x":1.3,"y":2,"w":3,"h":4}"#)
        #expect(FocusEvent(tUs: 18_446_744_073_709_551_615, signal: .cut).json == #"{"t_us":18446744073709551615,"kind":"cut"}"#)
    }

    @Test func theJSONParsesWithTheTagAndTimeAtTheTop() throws {
        let text = FocusEvent(tUs: 99, signal: .window(id: 7, CGRect(x: 1, y: 2, width: 3, height: 4))).json
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["t_us", "kind", "id", "x", "y", "w", "h"])
        #expect(object["kind"] as? String == "window")
        #expect((object["t_us"] as? NSNumber)?.uint64Value == 99)
    }

    @Test func coordinatesNeverEncodeAsExponentsOrNonFiniteNumbers() {
        #expect(FocusEvent(tUs: 1, signal: .pointer(x: 0.000_01, y: 1e7)).json == #"{"t_us":1,"kind":"pointer","x":0,"y":10000000}"#)
        #expect(FocusEvent(tUs: 1, signal: .pointer(x: .nan, y: 1)).json == #"{"t_us":1,"kind":"pointer","x":0,"y":1}"#)
    }

    // MARK: Damage

    @Test func nearbyDamageMergesAndTheLargestRegionsGoFirst() {
        var damage = FocusDamage()
        // A terminal's text rows (touching), a far clock and a far cursor blink.
        damage.add([CGRect(x: 100, y: 100, width: 800, height: 30), CGRect(x: 100, y: 130, width: 800, height: 30)])
        damage.add([CGRect(x: 3000, y: 0, width: 100, height: 40)])
        damage.add([CGRect(x: 2000, y: 2000, width: 10, height: 20)])
        damage.add([CGRect(x: 120, y: 165, width: 10, height: 20)])
        let regions = damage.drain(limit: 2)
        #expect(regions == [CGRect(x: 100, y: 100, width: 800, height: 85), CGRect(x: 3000, y: 0, width: 100, height: 40)])
        #expect(damage.drain(limit: 2).isEmpty, "drained")
    }

    @Test func aStormOfRectsStaysBounded() {
        var damage = FocusDamage()
        for i in 0 ..< 10_000 { damage.add([CGRect(x: Double(i % 100) * 200, y: Double(i / 100) * 200, width: 10, height: 10)]) }
        #expect(damage.count <= FocusDamage.maximumRegions)
        #expect(damage.drain(limit: 3).count == 3)
    }

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
        let geometry = retina
        return FocusSignalProducer(probe: probe, geometry: { geometry }, send: { sent.send($0) })
    }

    @Test func withoutAccessibilityThePointerWindowAndDamageStillGo() {
        let probe = FakeProbe(), sent = Sent()
        let producer = makeProducer(probe, sent)
        producer.damage([CGRect(x: 10, y: 10, width: 20, height: 20)], captured: CGSize(width: 3456, height: 2234))
        for tick in 0 ..< FocusSignalProducer.ticksPerSecond { producer.tick(now: UInt64(tick) * 33_000) }
        let kinds = sent.kinds
        #expect(kinds.first == "source", "the size first")
        #expect(kinds.contains("pointer"))
        #expect(kinds.contains("window"))
        #expect(kinds.contains("damage"))
        #expect(!kinds.contains("caret"))
        #expect(sent.lock.withLock { sent.messages }.contains(#"{"t_us":0,"kind":"pointer","x":200,"y":200}"#))
    }

    @Test func aCaretGoesOnChangeAndEveryEventInDisplayPixels() {
        let probe = FakeProbe(), sent = Sent()
        probe.caretAt = CGRect(x: 50, y: 60, width: 0, height: 16)
        let producer = makeProducer(probe, sent)
        for tick in 0 ..< 4 { producer.tick(now: UInt64(tick) * 33_000) }
        let carets = sent.take().filter { $0.contains(#""kind":"caret""#) }
        #expect(carets == [#"{"t_us":0,"kind":"caret","x":100,"y":120,"w":0,"h":32}"#], "once while it stays")
        probe.lock.withLock { probe.caretAt = CGRect(x: 58, y: 60, width: 0, height: 16) }
        for tick in 4 ..< 8 { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.take().filter { $0.contains(#""kind":"caret""#) }.count == 1)
    }

    @Test func aStillPointerIsNotResentEveryTick() {
        let probe = FakeProbe(), sent = Sent()
        let producer = makeProducer(probe, sent)
        for tick in 0 ..< 10 { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.kinds.filter { $0 == "pointer" }.count == 1)
    }

    @Test func aNewWindowIdIsSentAtOnceAndTheWindowIsRepeatedForALateJoiner() {
        let probe = FakeProbe(), sent = Sent()
        let producer = makeProducer(probe, sent)
        let second = FocusSignalProducer.ticksPerSecond
        for tick in 0 ..< second { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.kinds.filter { $0 == "window" }.count == 1)
        _ = sent.take()
        for tick in second ..< 2 * second { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.kinds.filter { $0 == "window" }.count == 1, "re-sent once a second")
        #expect(sent.kinds.contains("source"), "the size too")
        _ = sent.take()
        probe.lock.withLock { probe.window = FocusWindow(id: 6, frame: CGRect(x: 10, y: 10, width: 400, height: 300)) }
        for tick in 2 * second ..< 2 * second + FocusSignalProducer.windowEvery { producer.tick(now: UInt64(tick) * 33_000) }
        #expect(sent.take().contains { $0.contains(#""kind":"window","id":6"#) })
    }

    @Test func damageIsCoalescedToAtMostThirtyMessagesASecond() {
        let probe = FakeProbe(), sent = Sent()
        let producer = makeProducer(probe, sent)
        for tick in 0 ..< FocusSignalProducer.ticksPerSecond {
            // Every frame damages scattered places.
            producer.damage((0 ..< 20).map { CGRect(x: Double($0) * 170, y: Double(tick % 10) * 200, width: 8, height: 8) },
                            captured: CGSize(width: 3456, height: 2234))
            producer.tick(now: UInt64(tick) * 33_000)
        }
        #expect(sent.kinds.filter { $0 == "damage" }.count <= 30)
        #expect(sent.kinds.filter { $0 == "damage" }.count > 0)
    }

    @Test func aClosedChannelResendsEverythingOnceItOpens() {
        let probe = FakeProbe(), sent = Sent()
        sent.open = false
        let producer = makeProducer(probe, sent)
        for tick in 0 ..< 3 { producer.tick(now: UInt64(tick) * 33_000) }
        sent.lock.withLock { sent.open = true }
        producer.tick(now: 3 * 33_000)
        let kinds = sent.kinds
        #expect(kinds.first == "source")
        #expect(kinds.contains("pointer"))
        #expect(kinds.contains("window"))
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
