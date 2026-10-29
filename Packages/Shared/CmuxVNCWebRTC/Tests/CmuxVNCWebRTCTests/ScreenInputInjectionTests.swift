#if os(macOS)
import CoreGraphics
@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// The CGEvents the Mac host would post for a viewer's input, captured
/// instead of posted (no Accessibility permission needed).
final class PostedEvents: @unchecked Sendable {
    // @unchecked: `events` is behind `lock`.
    private let lock = NSLock()
    private var events: [CGEvent] = []
    var all: [CGEvent] { lock.withLock { events } }
    func append(_ event: CGEvent) { lock.withLock { events.append(event) } }
    func of(_ types: Set<CGEventType>) -> [CGEvent] { all.filter { types.contains($0.type) } }
}

struct ScreenInputInjectionTests {
    static let command: UInt32 = 0xFFE7, shift: UInt32 = 0xFFE1, option: UInt32 = 0xFFE9

    private func injector() -> (EventInjector, PostedEvents) {
        let posted = PostedEvents()
        let injector = EventInjector(source: nil) { posted.append($0) }
        injector.display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        return (injector, posted)
    }

    /// The viewer sends a modifier down, the click, then the modifier up:
    /// the click is a modified click, and the pointer after the up is not.
    @Test(arguments: [(command, CGEventFlags.maskCommand), (shift, .maskShift), (option, .maskAlternate)])
    func aClickWhileAModifierIsDownCarriesIt(keysym: UInt32, flag: CGEventFlags) {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "key", k: keysym, d: true))
        injector.handle(ScreenInput(t: "move", x: 0.5, y: 0.5, b: 0))
        injector.handle(ScreenInput(t: "move", x: 0.5, y: 0.5, b: 1))
        injector.handle(ScreenInput(t: "move", x: 0.5, y: 0.5, b: 0))
        injector.handle(ScreenInput(t: "key", k: keysym, d: false))
        injector.handle(ScreenInput(t: "move", x: 0.6, y: 0.5, b: 0))

        let mouse = posted.of([.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(mouse.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp, .mouseMoved])
        #expect(mouse.prefix(3).allSatisfy { $0.flags.contains(flag) })
        #expect(!mouse[3].flags.contains(flag))
    }

    /// A held modifier stays on every mouse event (right and middle buttons,
    /// drags, scrolls) until its key up.
    @Test func aStickyModifierStaysOnEveryMouseEventUntilItsKeyUp() {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "key", k: Self.option, d: true))
        injector.handle(ScreenInput(t: "move", x: 0.1, y: 0.1, b: 4))
        injector.handle(ScreenInput(t: "move", x: 0.2, y: 0.1, b: 4))
        injector.handle(ScreenInput(t: "move", x: 0.2, y: 0.1, b: 0))
        injector.handle(ScreenInput(t: "move", x: 0.2, y: 0.1, b: 2))
        injector.handle(ScreenInput(t: "move", x: 0.2, y: 0.1, b: 0))
        injector.handle(ScreenInput(t: "scroll", x: 0.2, y: 0.1, dy: 2))
        let mouse = posted.all.filter { $0.type != .keyDown && $0.type != .keyUp && $0.type != .flagsChanged }
        #expect(mouse.count == 7)
        #expect(mouse.allSatisfy { $0.flags.contains(.maskAlternate) })
    }

    /// A chord for a modifier that is already held (sticky ⌘, then ⌘C)
    /// leaves it held: the click after it is still a ⌘-click.
    @Test func aChordKeepsAModifierTheViewerHolds() {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "key", k: Self.command, d: true))
        injector.handle(ScreenInput(t: "chord", k: 0x63, m: [Self.command]))
        injector.handle(ScreenInput(t: "move", x: 0.5, y: 0.5, b: 1))
        let keys = posted.of([.keyDown, .keyUp]).filter { $0.getIntegerValueField(.keyboardEventKeycode) == 8 }
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { $0.flags.contains(.maskCommand) })
        let down = posted.of([.leftMouseDown])
        #expect(down.count == 1)
        #expect(down.first?.flags.contains(.maskCommand) == true)
    }

    /// A chord with nothing held releases its modifiers after the key.
    @Test func aChordReleasesItsOwnModifiers() {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "chord", k: 0x63, m: [Self.command]))
        injector.handle(ScreenInput(t: "move", x: 0.5, y: 0.5, b: 1))
        let keys = posted.of([.keyDown, .keyUp]).filter { $0.getIntegerValueField(.keyboardEventKeycode) == 8 }
        #expect(keys.allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(posted.of([.leftMouseDown]).first?.flags.contains(.maskCommand) == false)
    }

    /// A move with a button held is that button's drag, with its button number.
    @Test(arguments: [(UInt8(1), CGEventType.leftMouseDragged, Int64(0)), (4, .rightMouseDragged, 1), (2, .otherMouseDragged, 2)])
    func aMoveWithAButtonHeldIsThatButtonsDrag(mask: UInt8, drag: CGEventType, button: Int64) {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "move", x: 0.1, y: 0.1, b: mask))
        injector.handle(ScreenInput(t: "move", x: 0.3, y: 0.4, b: mask))
        injector.handle(ScreenInput(t: "move", x: 0.3, y: 0.4, b: 0))
        let types = posted.all.map(\.type)
        #expect(types.count == 3)
        #expect(types.dropFirst().first == drag)
        let dragged = posted.all[1]
        #expect(dragged.getIntegerValueField(.mouseEventButtonNumber) == button)
        #expect(dragged.location == CGPoint(x: 300, y: 320))
    }

    /// Left wins over right, right over middle, when several are held.
    @Test func severalButtonsDragAsTheFirstOfLeftRightMiddle() {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "move", x: 0.1, y: 0.1, b: 6))
        injector.handle(ScreenInput(t: "move", x: 0.2, y: 0.1, b: 6))
        #expect(posted.all.last?.type == .rightMouseDragged)
        #expect(posted.all.last?.getIntegerValueField(.mouseEventButtonNumber) == 1)
    }

    /// Without `u` a scroll is lines, as every viewer sent it.
    @Test func aScrollWithoutAUnitIsLines() throws {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "scroll", x: 0.5, y: 0.5, dx: -1, dy: 3))
        let wheel = try #require(posted.of([.scrollWheel]).first)
        #expect(wheel.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        #expect(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
        #expect(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -1)
    }

    /// `u: "px"` is a pixel (continuous) scroll, same sign as a line scroll
    /// the same way, at the pointer.
    @Test func aPixelScrollIsContinuousWithTheLineScrollsSign() throws {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "scroll", x: 0.25, y: 0.5, dx: -7, dy: 13, u: ScreenInput.pixelUnit))
        #expect(posted.all.first?.location == CGPoint(x: 250, y: 400))
        let wheel = try #require(posted.of([.scrollWheel]).first)
        #expect(wheel.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 13)
        #expect(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -7)
    }

    /// A scroll while a button is held keeps the drag (no plain move between).
    @Test func aScrollDuringADragKeepsTheDrag() {
        let (injector, posted) = injector()
        injector.handle(ScreenInput(t: "move", x: 0.1, y: 0.1, b: 1))
        injector.handle(ScreenInput(t: "scroll", x: 0.2, y: 0.2, dy: 1, u: ScreenInput.pixelUnit))
        #expect(posted.all.map(\.type) == [.leftMouseDown, .leftMouseDragged, .scrollWheel])
    }

    @Test func theCaptureBackendAdvertisesPixelScrollAndModifiedClicks() {
        #expect(ScreenCaptureBackend(log: { _ in }).inputCapabilities == ["scroll-px", "mods"])
    }
}

struct ScreenInputWireTests {
    @Test func aScrollFromAnOlderViewerStillDecodesAsLines() throws {
        let input = try JSONDecoder().decode(ScreenInput.self, from: Data(#"{"t":"scroll","x":0.5,"y":0.5,"dx":0,"dy":3}"#.utf8))
        #expect(input.u == nil)
        #expect(input.dy == 3)
    }

    @Test func aPixelScrollDecodes() throws {
        let input = try JSONDecoder().decode(ScreenInput.self, from: Data(#"{"t":"scroll","x":0.5,"y":0.5,"dx":-4,"dy":12,"u":"px"}"#.utf8))
        #expect(input.u == "px")
        #expect(input.dx == -4)
        #expect(input.dy == 12)
    }

    /// A viewer that sends fractional pixels must not lose the scroll (an Int field would fail the whole message).
    @Test func fractionalPixelsRoundInsteadOfDroppingTheMessage() throws {
        let input = try JSONDecoder().decode(ScreenInput.self, from: Data(#"{"t":"scroll","x":0.5,"y":0.5,"dx":-2.4,"dy":2.6,"u":"px"}"#.utf8))
        #expect(input.dx == -2)
        #expect(input.dy == 3)
    }

    /// A message without `u` encodes as before (no `u` key for an older host to meet).
    @Test func noUnitEncodesNoKey() throws {
        let data = try JSONEncoder().encode(ScreenInput(t: "scroll", x: 0.5, y: 0.5, dy: 3))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["u"] == nil)
    }

    @Test func theCapsMessageListsTheBackendsCapabilities() throws {
        let message = try #require(ScreenStreamHost.capabilitiesMessage(for: ["scroll-px", "mods"], viewOnly: false))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(object.count == 2)
        #expect(object["t"] as? String == "caps")
        #expect(object["s"] as? String == "scroll-px,mods")
    }

    /// A view-only session takes no input, and a backend with nothing new says nothing.
    @Test func noCapsForAViewOnlySessionOrABackendWithoutAny() {
        #expect(ScreenStreamHost.capabilitiesMessage(for: ["scroll-px", "mods"], viewOnly: true) == nil)
        #expect(ScreenStreamHost.capabilitiesMessage(for: [], viewOnly: false) == nil)
    }

    /// The viewer reads `caps` as capabilities, never as a displays message
    /// (which would clear its display list).
    @Test func theViewerReadsCapsAsCapabilitiesNotDisplays() throws {
        let caps = try JSONDecoder().decode(ScreenHostMessage.self, from: Data(#"{"t":"caps","s":"scroll-px,mods"}"#.utf8))
        #expect(ScreenStreamViewer.capabilities(in: caps) == ["scroll-px", "mods"])
        #expect(!ScreenStreamViewer.isDisplays(caps))
        let displays = ScreenHostMessage(t: "displays", displays: [.init(w: 10, h: 10)], current: 0)
        #expect(ScreenStreamViewer.capabilities(in: displays) == nil)
        #expect(ScreenStreamViewer.isDisplays(displays))
    }

    /// Pixel scrolls and modifier keys from a view-only viewer never reach the Mac.
    @Test func aViewOnlyHostIgnoresPixelScrollsAndModifiers() {
        let backend = RecordingBackend()
        let host = ScreenStreamHost(name: "Studio", viewOnly: true, backend: { backend }, log: { _ in })
        for input in [ScreenInput(t: "key", k: 0xFFE7, d: true), ScreenInput(t: "move", x: 0.5, y: 0.5, b: 1),
                      ScreenInput(t: "scroll", x: 0.5, y: 0.5, dy: 40, u: ScreenInput.pixelUnit)] {
            host.deliver(input, to: backend)
        }
        #expect(backend.handled.isEmpty)
    }
}
#endif
