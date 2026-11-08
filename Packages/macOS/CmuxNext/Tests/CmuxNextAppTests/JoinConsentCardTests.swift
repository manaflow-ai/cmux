import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The join consent's one-time ask on its own server card panel (`#/join-consent`): the provider and the
/// panel that decide what the page's Deny and the native Allow may do (ported from JoinConsentTests'
/// sheet tests when the ask moved to React). SECURITY (cmux#33066, HQ#5121): Allow is the panel's own
/// click-only button, not a page control, and it answers only the person's own click on it, read by
/// the panel from the click's own events: never a page call, a click the strict check refuses (an
/// Accessibility press, a posted or programmatic click), a click elsewhere on the card, a click begun
/// before the card last drew, or a click while a write is in flight. cmux's own captures leave the
/// panel out by id and Computer Use refuses it.
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
        /// The event AppKit has in hand (the mouse-up inside the mouse-down's dispatch).
        var currentEvent: NSEvent?

        init() {
            model = JoinConsentModel(services: fake.services())
        }

        /// The center of the native Allow, in the panel's window coordinates.
        var onAllow: NSPoint {
            panel.personButton.convert(NSPoint(x: panel.personButton.bounds.midX, y: panel.personButton.bounds.midY), to: nil)
        }

        /// A click at `point` `after` seconds from now, the person's unless `person` is false, its
        /// mouse-up inside the mouse-down's dispatch (a button's tracking loop).
        func click(at point: NSPoint? = nil, after: TimeInterval, person: Bool = true) throws {
            let point = point ?? onAllow
            let time = ProcessInfo.processInfo.systemUptime + after
            let down = try event(.leftMouseDown, point, time), up = try event(.leftMouseUp, point, time + 0.05)
            genuine.insert(down.eventNumber)
            if person { genuine.insert(up.eventNumber) }
            currentEvent = down
            panel.dispatch(down) { currentEvent = up }
        }

        private func event(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number,
                                                   clickCount: 1, pressure: 1))
        }

        /// A key on the panel: its time is a gesture, never a click.
        func key() -> TimeInterval {
            number += 1
            genuine.insert(number)
            return ProcessInfo.processInfo.systemUptime
        }

        /// A page call.
        func call(_ op: String, gesture: TimeInterval?, params: JSONValue = .null) async throws -> JSONValue {
            let context = PageCallContext(page: "cmux.server-cards", userGesture: gesture != nil, gestureEvent: gesture)
            return try await provider.call(op, params: params, context: context)
        }

        /// The provider names its control again (as it does on every change it hears).
        func update() {
            panel.setPersonControl(provider.personControl, card: provider.card)
            panel.contentView?.layoutSubtreeIfNeeded()
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
        panel.present(card: JoinConsentCardProvider.route, over: nil, takeKeys: false)
        panel.pageResized(card: JoinConsentCardProvider.route, width: 380, height: 160)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.personClick.eventInHand = { [weak ask] in ask?.currentEvent }
        panel.isKeyForPerson = { _ in true }
        panel.doubleClickInterval = { 0.5 }
        return ask
    }

    @Test func theStatusNamesWhoAskedForWhatAndWhyAnAllowDidNotTake() async throws {
        let ask = try await ask(.control)
        let status = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(status == ["ask": ["requester": "lane-vm-3", "surface": "control"], "error": .null, "writing": false])
        ask.fake.takes = false
        try ask.click(after: 1)
        for _ in 0..<1000 where ask.model.askError == nil { await Task.yield() }
        let failed = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(failed["error"]?.stringValue?.isEmpty == false && failed["ask"] != JSONValue.null, "the ask stays up with the reason")
    }

    /// Allow is the panel's native button while an ask shows; the page has no Allow op, whatever
    /// gesture or params it sends.
    @Test func allowIsTheNativeButtonAndNoPageCallGrants() async throws {
        let ask = try await ask()
        #expect(!ask.panel.personButton.isHidden && ask.panel.personButton.title == JoinConsentStrings.allow)
        #expect(ask.panel.personButton.isEnabled)
        let forged: JSONValue = ["action": "allow"]
        for gesture in [nil, ask.key()] {
            await #expect(throws: PageError.self) {
                _ = try await ask.call("cmux.joinConsent.allow", gesture: gesture, params: forged)
            }
        }
        await ask.settle()
        #expect(ask.fake.writes.isEmpty && ask.model.ask != nil)
    }

    /// Allow answers only the person's own click on it: not a posted or scripted click, not a click
    /// elsewhere on the card, not a click begun right after Allow appeared, not on a panel that is not key.
    @Test func allowAnswersOnlyThePersonsOwnClickOnIt() async throws {
        let ask = try await ask()
        try ask.click(after: 0.05)
        #expect(ask.fake.writes.isEmpty, "a click begun right after Allow appeared")
        try ask.click(after: 1, person: false)
        try ask.click(at: NSPoint(x: 10, y: 10), after: 2)
        ask.panel.isKeyForPerson = { _ in false }
        try ask.click(after: 3)
        ask.panel.isKeyForPerson = { _ in true }
        await ask.settle()
        #expect(ask.fake.writes.isEmpty && ask.model.ask != nil, "a scripted click, a click on the words, a panel not key")
        try ask.click(after: 4)
        await ask.settle()
        #expect(ask.fake.writes == ["screen true"] && ask.model.ask == nil)
        ask.update()
        #expect(ask.panel.personButton.isHidden, "no ask, no Allow")
    }

    /// One click answers once, and while a write is in flight Allow is off and neither it nor Deny does
    /// anything: no second grant and no Deny closing the ask over a grant still landing.
    @Test func whileAWriteIsInFlightNeitherButtonActsAndOneClickAnswersOnce() async throws {
        let ask = try await ask()
        let gate = Gate()
        ask.fake.beforeWrite = { await withCheckedContinuation { gate.release = $0 } }
        try ask.click(after: 1)
        for _ in 0..<1000 where gate.release == nil { await Task.yield() }
        #expect(ask.model.writing)
        let status = try await ask.call(JoinConsentCardProvider.statusOp, gesture: nil)
        #expect(status["writing"]?.boolValue == true)
        ask.update()
        #expect(!ask.panel.personButton.isEnabled, "Allow is off while the write is in flight")
        ask.provider.personPressed()
        _ = try await ask.call(JoinConsentCardProvider.denyOp, gesture: ask.key())
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
        _ = try await ask.call(JoinConsentCardProvider.denyOp, gesture: ask.key())
        await ask.settle()
        #expect(ask.model.ask == nil && ask.fake.writes.isEmpty)
    }

    /// SECURITY: the ask's panel is its own, asking every capture to skip it (Computer Use refuses a window
    /// with `sharingType` none, MacCuaTargetResolver; cmux's own captures, the next test), over every app at the top right of the main
    /// screen, never moved by its background, and Escape or the page's cancel never denies or hides it.
    @Test func theAsksPanelStaysOutOfCaptureAtTheTopRight() async throws {
        let ask = try await ask()
        let panel = ask.panel!
        #expect(panel.sharingType == .none)
        #expect(panel.page.refusesProbes && !panel.page.webKitView.isInspectable, "no page probe or Web Inspector reaches the ask")
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.stationary) && panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.isMovableByWindowBackground && !panel.becomesKeyOnlyIfNeeded && panel.ordersFrontRegardless)
        #expect(panel.cards.keys.sorted() == [JoinConsentCardProvider.route], "no other card shares the ask's panel")
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(WebCardPanel.joinConsentPlacement(size: CGSize(width: 380, height: 180), in: visible)
            == NSRect(x: 1440 - 380 - 16, y: 875 - 180 - 16, width: 380, height: 180))
        #expect(!panel.cancelHides)
        let shown = panel.isVisible
        #expect(shown, "the ask shows once the page reports its size")
        // No page listens in the test (its scratch page has no script): the panel's own policy holds.
        panel.cancelOperation(nil)
        await ask.settle()
        #expect(ask.model.ask != nil && ask.fake.writes.isEmpty, "Escape denies nothing")
        #expect(panel.isVisible == shown, "Escape never hides the ask, even with no page listening")
    }

    /// SECURITY (cmux#37286): macOS 15.4+ may capture a window with `sharingType` none, so every capture cmux
    /// makes leaves the ask out by its window id: screen sharing, `cmux rd serve` and the recorders read
    /// ``CaptureExcludedWindows``, which lists it while it shows.
    @Test func cmuxsOwnCapturesLeaveTheAskOut() async throws {
        let ask = try await ask()
        let panel = ask.panel!
        let id = CGWindowID(panel.windowNumber)
        #expect(panel.isVisible && id > 0)
        // The window server takes the new window in its own time.
        for _ in 0..<40 where !CaptureExcludedWindows.windowIDs().contains(id) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(CaptureExcludedWindows.windowIDs().contains(id), "left out of cmux's captures")
        panel.orderOut(nil)
    }

    /// A page size reported after the panel showed (the first one late, after the fallback size, or one
    /// at a larger Interface Scale) keeps the ask at the top right, inside the screen, never re-centered
    /// past its right edge where Allow would be cut off.
    @Test func aLaterWiderSizeKeepsTheAskAtTheTopRight() async throws {
        let ask = try await ask()
        let panel = ask.panel!
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        #expect(panel.frame == WebCardPanel.joinConsentPlacement(size: panel.frame.size, in: visible))
        panel.pageResized(card: JoinConsentCardProvider.route, width: 570, height: 240)
        #expect(panel.frame.width >= 570)
        #expect(panel.frame == WebCardPanel.joinConsentPlacement(size: panel.frame.size, in: visible))
        if let visible {
            #expect(panel.frame.maxX == visible.maxX - WebCardPanel.joinConsentInset, "Allow stays on screen")
        }
    }

    /// SECURITY (cmux#37286): the card page lays out the ask around the native Allow, so it runs only
    /// the app's bundled script. Its policy allows script from its own bundle and nothing else: no inline
    /// script, no eval, no remote script; no frame, connection or media; and the dev server never
    /// serves it. With page probes and Web Inspector refused (the panel test above), only shipped
    /// code can change what the card shows.
    @Test func theCardPageRunsOnlyItsBundledScript() throws {
        let directives = Dictionary(uniqueKeysWithValues: PageDescriptor.serverCards.csp.header
            .split(separator: ";").map { $0.split(separator: " ").map(String.init) }.compactMap { parts in
                parts.first.map { ($0, Array(parts.dropFirst())) }
            })
        #expect(directives["default-src"] == ["'none'"])
        #expect(directives["script-src"] == ["'self'"], "no 'unsafe-inline', 'unsafe-eval' or remote source")
        for absent in ["connect-src", "frame-src", "media-src", "child-src", "object-src"] {
            #expect(directives[absent] == nil, "\(absent) stays 'none' through default-src")
        }
        #expect(!(directives["img-src"] ?? []).contains { $0.hasPrefix("http") }, "no remote image")
        #expect(PageDevServer.bundledOnlyPageIDs.contains(PageDescriptor.serverCards.id))
    }

    private static let pageRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "join-consent-page-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        return directory
    }()
}
