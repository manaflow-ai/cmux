import AppKit
import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The join consent's one-time ask on its own server card panel (`#/join-consent`): the provider and the
/// panel that decide what the page's Deny and Allow may do (ported from JoinConsentTests' sheet tests when
/// the ask moved to React). SECURITY (cmux#33066, HQ#5121): Allow answers only the person's own click on
/// the card, read by the panel from the click's own events: never a call with no gesture, a key's
/// gesture, a click the strict check refuses (an Accessibility press, a posted or programmatic click), a
/// click begun before the card last drew, or the same click twice; never while a write is in flight. The
/// panel stays out of screen capture, so Computer Use refuses it and no capture shows Allow.
@MainActor @Suite(.serialized) struct JoinConsentCardTests {
    typealias Fake = JoinConsentTests.Fake

    /// Holds a write between the model's last check and its bytes.
    final class Gate {
        var release: CheckedContinuation<Void, Never>?
    }

    /// The ask showing on its panel, with the events the person made (the strict check's stand-in).
    final class Ask {
        let fake = Fake()
        let model: JoinConsentModel
        var panel: WebCardPanel!
        var provider: JoinConsentCardProvider!
        var genuine: Set<Int> = []
        private var number = 0
        /// Event times, past the arming's double-click interval.
        private var clock: TimeInterval = 100

        init() {
            model = JoinConsentModel(services: fake.services())
        }

        /// Where Allow and Deny are, in the panel's window, and another spot on the card (the words).
        /// All are outside the card's views: the panel reads the click, no view takes it.
        static let allowAt = NSPoint(x: -50, y: -50)
        static let denyAt = NSPoint(x: -150, y: -50)
        static let elsewhere = NSPoint(x: -250, y: -50)

        /// The page's controls as the panel's hit test finds them (its stand-in for the page's DOM):
        /// `data-action` by the point's place in the page.
        func control(at point: CGPoint) -> String? {
            [(Self.allowAt, "allow"), (Self.denyAt, "deny")].first { panel.pagePoint($0.0) == point }?.1
        }

        /// One left click on the panel at `at`: its mouse-down and mouse-up, the person's when `person`.
        /// Returns the mouse-up's time, which the page's call carries as its gesture.
        @discardableResult
        func click(person: Bool = true, at point: NSPoint = allowAt) throws -> TimeInterval {
            let down = try event(.leftMouseDown, at: point), up = try event(.leftMouseUp, at: point)
            if person { genuine.formUnion([down.eventNumber, up.eventNumber]) }
            panel.sendEvent(down)
            panel.sendEvent(up)
            return up.timestamp
        }

        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            number += 1
            clock += 0.05
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: clock,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                                                   pressure: 0))
        }

        /// A key on the panel: its time is a gesture, never a click.
        func key() throws -> TimeInterval {
            number += 1
            clock += 0.05
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: clock,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            genuine.insert(number)
            panel.sendEvent(event)
            return clock
        }

        /// The card drew anew now (as its provider does on every change).
        func redraw() {
            panel.rearm(at: clock)
            clock += NSEvent.doubleClickInterval
        }

        /// A page call. Whatever the page sends, it names no control: the panel's hit test does.
        func call(_ op: String, gesture: TimeInterval?, params: JSONValue = .null) async throws -> JSONValue {
            let context = PageCallContext(page: "cmux.server-cards", userGesture: gesture != nil, gestureEvent: gesture)
            return try await provider.call(op, params: params, context: context)
        }

        func allow(_ gesture: TimeInterval?, params: JSONValue = .null) async -> Bool {
            do {
                _ = try await call(JoinConsentCardProvider.allowOp, gesture: gesture, params: params)
                return true
            } catch let error as PageError {
                #expect(error.code == PageNativeOp.userOnlyCode)
                return false
            } catch {
                Issue.record("allow threw \(error)")
                return false
            }
        }

        func settle() async {
            for _ in 0..<1000 where model.ask != nil || model.writing { await Task.yield() }
        }
    }

    func ask(_ surface: JoinConsentSurface = .screen) async throws -> Ask {
        let root = try #require(Self.pageRoot, "no scratch page root")
        PageID.registerBundledRoot(root, for: PageDescriptor.serverCards.id) // the built page wins when bundled
        _ = NSApplication.shared
        let ask = Ask()
        await ask.model.refresh()
        ask.model.refused(JoinConsentRefusal(requester: "lane-vm-3", surface: surface))
        // The closure stays out of #require: inside the macro it crashed the compiler's diagnostics.
        let isPersonEvent: @MainActor (NSEvent) -> Bool = { [weak ask] in ask?.genuine.contains($0.eventNumber) ?? false }
        let made = WebCardPanel.joinConsent(model: ask.model, isPersonEvent: isPersonEvent)
        let panel = try #require(made)
        ask.panel = panel
        ask.provider = try #require(panel.cards[JoinConsentCardProvider.route] as? JoinConsentCardProvider)
        panel.controlAt = { [weak ask] point, done in done(ask?.control(at: point)) }
        panel.rearm(at: 0)
        return ask
    }

    @Test func theStatusNamesWhoAskedForWhatAndWhyAnAllowDidNotTake() async throws {
        let ask = try await ask(.control)
        let status = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(status == ["ask": ["requester": "lane-vm-3", "surface": "control"], "error": .null, "writing": false])
        ask.fake.takes = false
        let up = try ask.click()
        #expect(await ask.allow(up))
        for _ in 0..<1000 where ask.model.askError == nil { await Task.yield() }
        let failed = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(failed["error"]?.stringValue?.isEmpty == false && failed["ask"] != JSONValue.null, "the ask stays up with the reason")
    }

    /// Allow answers only the person's own click on the card: not a call without a gesture (page script),
    /// not a key's gesture (Return on a focused Allow), not a click the strict check refuses (an
    /// Accessibility press, a posted or programmatic click), not a click begun before the card drew anew,
    /// not a gesture that is not the panel's last click, and not the same click twice.
    @Test func allowAnswersOnlyThePersonsOwnClickOnTheCard() async throws {
        let ask = try await ask()
        #expect(!(await ask.allow(nil)), "page script, no gesture")
        let key = try ask.key()
        #expect(!(await ask.allow(key)), "a key's gesture")
        let posted = try ask.click(person: false)
        #expect(!(await ask.allow(posted)), "a click the strict check refuses")
        let early = try ask.click()
        ask.panel.rearm(at: early) // the card drew anew under a pointer aimed at what was there before
        #expect(!(await ask.allow(early)), "a click begun before the card drew anew")
        ask.redraw()
        let old = try ask.click()
        try ask.click()
        #expect(!(await ask.allow(old)), "a gesture that is not the panel's last click")
        let afterKey = try ask.click()
        _ = try ask.key()
        #expect(!(await ask.allow(afterKey)), "a key after the click ends it")
        await ask.settle()
        #expect(ask.fake.writes.isEmpty && ask.model.ask != nil)
        let up = try ask.click()
        #expect(await ask.allow(up))
        #expect(!(await ask.allow(up)), "the same click twice")
        await ask.settle()
        #expect(ask.fake.writes == ["screen true"] && ask.model.ask == nil)
    }

    /// SECURITY (review F1 on cmux#37286): a genuine click must land on Allow itself, as the panel's
    /// own hit test reads it; nothing the page sends names the control. A real click on the card's
    /// words or on Deny, then a script's press of Allow carrying that click's gesture (and a rect or
    /// action of its choosing), grants nothing; neither does a drag that began elsewhere.
    @Test func allowNeedsTheClickToLandOnAllow() async throws {
        let ask = try await ask()
        let forged: JSONValue = ["target": ["x": -10_000, "y": -10_000, "width": 20_000, "height": 20_000], "action": "allow"]
        let elsewhere = try ask.click(at: Ask.elsewhere)
        #expect(!(await ask.allow(elsewhere, params: forged)), "a real click on the words, then a script's press of Allow")
        let onDeny = try ask.click(at: Ask.denyAt)
        #expect(!(await ask.allow(onDeny, params: forged)), "a real click on Deny, then a script's press of Allow")
        let down = try ask.event(.leftMouseDown, at: Ask.elsewhere), up = try ask.event(.leftMouseUp, at: Ask.allowAt)
        ask.genuine.formUnion([down.eventNumber, up.eventNumber])
        ask.panel.sendEvent(down)
        ask.panel.sendEvent(up)
        #expect(!(await ask.allow(up.timestamp)), "a drag that began elsewhere and ended on Allow")
        await ask.settle()
        #expect(ask.fake.writes.isEmpty && ask.model.ask != nil)
        let real = try ask.click()
        #expect(await ask.allow(real), "the person's click on Allow")
        await ask.settle()
        #expect(ask.fake.writes == ["screen true"])
    }

    /// SECURITY (review F2 on cmux#37286): the hit test answers later than the click; a card that drew
    /// anew while it was pending (a new ask, a new machine) takes nothing from that click.
    @Test func aClickWhoseHitTestOutlivesARedrawGrantsNothing() async throws {
        let ask = try await ask()
        var held: [@MainActor (String?) -> Void] = []
        ask.panel.controlAt = { _, done in held.append(done) }
        let up = try ask.click()
        // task-owner: the test's own call, awaited below
        let answer = Task { await ask.allow(up) }
        for _ in 0..<1000 where held.count < 2 { await Task.yield() }
        ask.redraw()
        for done in held { done("allow") }
        #expect(!(await answer.value), "the card drew anew while the click was checked")
        await ask.settle()
        #expect(ask.fake.writes.isEmpty && ask.model.ask != nil)
    }

    /// One click answers once, and while a write is in flight (both buttons off) neither Allow nor Deny
    /// does anything: no second grant and no Deny closing the ask over a grant still landing.
    @Test func whileAWriteIsInFlightNeitherButtonActsAndOneClickAnswersOnce() async throws {
        let ask = try await ask()
        let gate = Gate()
        ask.fake.beforeWrite = { await withCheckedContinuation { gate.release = $0 } }
        let first = try ask.click()
        #expect(await ask.allow(first))
        for _ in 0..<1000 where gate.release == nil { await Task.yield() }
        #expect(ask.model.writing)
        let status = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(status["writing"]?.boolValue == true)
        let second = try ask.click()
        #expect(await ask.allow(second), "a press while writing is no answer, not a refusal")
        _ = try await ask.call(JoinConsentCardProvider.denyOp, gesture: try ask.click())
        #expect(ask.model.ask != nil, "a Deny never closes the ask over a grant still landing")
        ask.fake.beforeWrite = nil
        gate.release?.resume()
        await ask.settle()
        #expect(ask.fake.writes == ["screen true"] && ask.model.ask == nil)
    }

    /// Deny needs the person's gesture (a key or a click, never page script alone) and writes nothing.
    @Test func denyNeedsAGestureAndWritesNothing() async throws {
        let ask = try await ask()
        await #expect(throws: PageError.self) { _ = try await ask.call(JoinConsentCardProvider.denyOp, gesture: nil) }
        #expect(ask.model.ask != nil)
        _ = try await ask.call(JoinConsentCardProvider.denyOp, gesture: try ask.key())
        await ask.settle()
        #expect(ask.model.ask == nil && ask.fake.writes.isEmpty)
    }

    /// SECURITY: the ask's panel is its own, out of screen capture and screen sharing (Computer Use refuses
    /// a window with `sharingType` none, MacCuaTargetResolver), over every app at the top right of the main
    /// screen, never moved by its background, and Escape or the page's cancel never denies or hides it.
    @Test func theAsksPanelStaysOutOfCaptureAtTheTopRight() async throws {
        let ask = try await ask()
        let panel = ask.panel!
        #expect(panel.sharingType == .none)
        #expect(panel.page.refusesProbes && !panel.page.webKitView.isInspectable, "no page probe or Web Inspector reaches the ask")
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.stationary) && panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.isMovableByWindowBackground && panel.becomesKeyOnlyIfNeeded && panel.ordersFrontRegardless)
        #expect(panel.cards.keys.sorted() == [JoinConsentCardProvider.route], "no other card shares the ask's panel")
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(WebCardPanel.joinConsentPlacement(size: CGSize(width: 380, height: 180), in: visible)
            == NSRect(x: 1440 - 380 - 16, y: 875 - 180 - 16, width: 380, height: 180))
        panel.cancelOperation(nil)
        await ask.settle()
        #expect(ask.model.ask != nil && ask.fake.writes.isEmpty, "Escape denies nothing")
    }

    private static let pageRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "join-consent-page-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        return directory
    }()
}
