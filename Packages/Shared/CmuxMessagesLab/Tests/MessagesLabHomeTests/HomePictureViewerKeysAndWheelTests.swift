import AppKit
import CmuxHomeCore
import CoreGraphics
import Testing
@testable import MessagesLabHome

/// The picture viewer over a Chief chat in the app (the user, 2026-11-11, on a "Scrollbar · Dark" shot: "pressing
/// esc doesnt work, i also want to be able to scroll with my external mouse", and "center it with the button").
///
/// - Esc: Home moves the keyboard to its message box whenever the pane gets focus and nothing that keeps the
///   keyboard has it (`composeShouldTakeKeyboard`, run by the app's focus pass). The open viewer did not count, so
///   a focus pass took the keyboard from it and Esc went to the box. These drive a real `ChatController` with the
///   viewer mounted over its pane, run that focus pass, then press Esc where the keyboard is.
/// - Wheel: a mouse wheel (line steps, no trackpad pinch) did nothing on a fitted picture. It zooms about the pointer,
///   as in Photos; a trackpad scroll still pans.
/// - Title: the title's letters sit on the round compose button's centre line, not 4 points above it.
@MainActor @Suite(.serialized) struct HomePictureViewerKeysAndWheelTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// A Chief chat pane in an offscreen window, as `EmojiButtonTests` builds it.
    static func pane() -> (NSWindow, ChatController) {
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...2).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? me : them,
                           parts: [.text("Message number \(i)")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_viewer_keys"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_viewer_keys"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 800, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.bringWindowForward = { _ in }
        return (window, controller)
    }

    static func gallery() -> HomePictureGallery {
        HomePictureGallery(items: [.init(source: "s0", url: URL(fileURLWithPath: "/tmp/s0.png"), title: "Scrollbar · Dark", row: 0, column: 0)],
                           index: 0)
    }

    /// The viewer opened over `controller`'s pane the way a click opens it (``ChatController/presentPictures``).
    static func openViewer(over controller: ChatController, closed: @escaping () -> Void) async throws -> HomePictureViewer {
        let picture = try HomePictureViewerTests.image(width: 1600, height: 1000, gray: 0.5)
        controller.presentPictures(gallery()) { _ in picture }
        let viewer = try #require(controller.pictureViewer)
        let close = viewer.onClose
        viewer.onClose = { close(); closed() }
        viewer.reduceMotion = { true }
        await viewer.loaded()
        viewer.layoutSubtreeIfNeeded()
        return viewer
    }

    /// The app's focus pass over Home (`PrimaryInputTarget`, `FocusEffectApplier`): the message box takes the
    /// keyboard unless what has it keeps it.
    static func focusPass(_ window: NSWindow, _ controller: ChatController) {
        if controller.composeShouldTakeKeyboard(from: window.firstResponder) { controller.focusCompose() }
    }

    @Test func aFocusPassLeavesTheOpenViewerTheKeyboardSoOneEscClosesIt() async throws {
        let (window, controller) = Self.pane()
        var closed = 0
        let viewer = try await Self.openViewer(over: controller) { closed += 1 }
        #expect(window.firstResponder === viewer, "the viewer takes the keyboard when it opens")

        Self.focusPass(window, controller)
        #expect(window.firstResponder === viewer, "a focus pass moved the keyboard to \(String(describing: window.firstResponder))")

        window.firstResponder?.keyDown(with: try HomePictureViewerCloseAndFlipTests.key("\u{1b}", code: HomePictureViewerCloseAndFlipTests.escape))
        #expect(closed == 1, "one Esc closes the viewer")
    }

    @Test func anEscWhileTheBoxUnderTheViewerHasTheKeyboardStillClosesIt() async throws {
        let (window, controller) = Self.pane()
        var closed = 0
        let viewer = try await Self.openViewer(over: controller) { closed += 1 }
        let field = try #require(controller.demo?.compose.textView.view)
        #expect(window.makeFirstResponder(field))
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        try #require(esc.window === window)
        #expect(viewer.claimsEscape(esc), "the viewer's window monitor takes the Esc")
        #expect(closed == 1)
        #expect(!viewer.claimsEscape(esc), "a closed viewer leaves Esc to the pane")
    }

    @Test func theOpenViewerIsWhereHomesKeyboardAndTypedKeysGo() async throws {
        let (_, controller) = Self.pane()
        let field = try #require(controller.demo?.compose.textView.view)
        #expect(controller.keyboardTarget === field)
        let viewer = try await Self.openViewer(over: controller) {}
        #expect(controller.keyboardTarget === viewer)
        #expect(!controller.historyTakesArrowKeys(from: viewer), "Up and Down are the viewer's, not the box's history")
        viewer.close()
        #expect(controller.keyboardTarget === field, "a closing viewer gives the box its keyboard back")
    }

    /// A wheel event of `lines` notches (positive: the wheel turned away from the person) with no phase and no
    /// precise deltas, as an external mouse sends; `pixels` makes it a trackpad's precise scroll instead.
    static func wheel(_ lines: Int32, pixels: Bool = false) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    static func scrollView(_ viewer: HomePictureViewer) throws -> NSScrollView {
        try #require(viewer.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    @Test func aMouseWheelZoomsTheFittedPictureInAndOut() async throws {
        let (_, controller) = Self.pane()
        let viewer = try await Self.openViewer(over: controller) {}
        let scroll = try Self.scrollView(viewer)
        let fitted = scroll.magnification
        #expect(fitted < 1, "a 800-point-wide picture fits a narrower area")

        scroll.scrollWheel(with: try Self.wheel(2))
        let zoomedIn = scroll.magnification
        #expect(zoomedIn > fitted * 1.2, "a mouse wheel turned away zooms in (\(fitted) → \(zoomedIn))")

        scroll.scrollWheel(with: try Self.wheel(-4))
        #expect(scroll.magnification < zoomedIn, "a mouse wheel turned back zooms out")
        #expect(scroll.magnification >= scroll.minMagnification)
    }

    @Test func aTrackpadScrollStillPansAndNeverZooms() async throws {
        let (_, controller) = Self.pane()
        let viewer = try await Self.openViewer(over: controller) {}
        let scroll = try Self.scrollView(viewer)
        let fitted = scroll.magnification
        scroll.scrollWheel(with: try Self.wheel(40, pixels: true))
        #expect(abs(scroll.magnification - fitted) < 0.0001, "a trackpad scroll does not zoom")
    }

    /// The rows of `label`'s drawn letters, top and bottom, in the viewer's coordinates (y down).
    static func ink(_ label: NSTextField, in viewer: HomePictureViewer) throws -> (top: CGFloat, bottom: CGFloat) {
        let rep = try #require(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / label.bounds.height
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            if (0..<rep.pixelsWide).contains(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }) { rows.append(y) }
        }
        let first = try #require(rows.first), last = try #require(rows.last)
        let top = viewer.convert(CGPoint(x: 0, y: CGFloat(first) / scale), from: label).y
        let bottom = viewer.convert(CGPoint(x: 0, y: CGFloat(last + 1) / scale), from: label).y
        return (min(top, bottom), max(top, bottom))
    }

    @Test(arguments: [true, false])
    func theTitleSitsOnTheComposeButtonsCentreLine(compose: Bool) async throws {
        let title = "Scrollbar · Dark"
        let (viewer, button) = try await HomePictureViewerTopBarTests.open(width: 900, title: title, compose: compose)
        let label = try #require(viewer.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == title })
        let ink = try Self.ink(label, in: viewer)
        // Without the button, the bar's own middle.
        let line = button?.midY ?? HomePictureViewerTopBar.height / 2
        let middle = (ink.top + ink.bottom) / 2
        #expect(abs(middle - line) <= 1, "the title's letters (\(ink.top)–\(ink.bottom), middle \(middle)) are off the line at \(line)")
    }
}
