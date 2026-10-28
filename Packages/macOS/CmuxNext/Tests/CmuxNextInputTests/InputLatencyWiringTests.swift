import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import CmuxNextSignposts
import ObjectiveC
import Testing

/// The input latency wiring of `sendEvent`: which events open a slot and as what kind, where they
/// land, the layout's scroll take, synthetic input, frame updates, drags once per frame, and the `key.frame` and
/// `key.scroll_frame` intervals the slots carry. Slots close through ``InputLatencyTrackerTests/Harness``'s fake
/// commit boundary: a view's at its turn's commit, a terminal's, page's or agent pane's at its own frame or its
/// deadline (``InputLatencyTrackerTests/Harness/settle()``).
@MainActor
struct InputLatencyWiringTests {
    final class TerminalFake: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class FocusableFake: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Records the frame intervals the tracker begins and ends.
    @MainActor
    final class FrameIntervalRecorder: InputFrameIntervals {
        var begun: [(interval: InputFrameInterval, target: InputTarget)] = []
        var ended: [(target: InputTarget, outcome: CommitBoundary.Outcome)] = []

        func begin(_ token: InputLatencyToken, _ interval: InputFrameInterval, target: InputTarget,
                   eventTimestamp: TimeInterval) {
            begun.append((interval, target))
        }

        func end(_ token: InputLatencyToken, target: InputTarget, outcome: CommitBoundary.Outcome) {
            ended.append((target, outcome))
        }
    }

    final class AgentFake: NSView {}
    final class WebFake: NSView {}
    final class LayoutFake: NSView {}
    final class PageWindowFake: NSWindow {}

    /// Counts the hit tests the wiring asks for and answers `target`.
    final class Pointer {
        var target: InputTarget
        var hitTests = 0

        init(_ target: InputTarget) { self.target = target }

        func hit() -> InputTarget {
            hitTests += 1
            return target
        }
    }

    static func classifier() -> InputTargetClassifier {
        InputTargetClassifier(rules: [
            .view(TerminalFake.self, is: .terminal),
            .view(AgentFake.self, is: .agentPane),
            .window(PageWindowFake.self, is: .chromiumPage),
            .view(WebFake.self, is: .webkitPage),
            .textInputClient(is: .textView),
            .view(LayoutFake.self, is: .layout),
        ])
    }

    private func wiring(_ harness: InputLatencyTrackerTests.Harness,
                        windowChanged: @escaping @MainActor (NSWindow) -> Bool = { _ in false }) -> InputLatencyDispatch {
        InputLatencyDispatch(tracker: harness.tracker, classifier: Self.classifier(), frameInterval: { _ in 0.01 },
                             windowChanged: windowChanged)
    }

    /// A real scroll event with the CGEvent scroll phase (1 began, 2 changed, 4 ended) and momentum phase (1 began,
    /// 2 continue, 3 end) fields.
    private func scrollEvent(phase: Int64, momentum: Int64) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: momentum == 3 ? 0 : -4, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: event))
    }

    /// One event through the wiring as `sendEvent` runs it: open the slot, dispatch, finish the slot.
    @discardableResult
    private func send(_ wiring: InputLatencyDispatch, _ type: InputEventType, phase: InputScrollPhase = .none,
                      at timestamp: TimeInterval = 0.5, window: NSWindow? = nil, keyWindow: NSWindow? = nil,
                      synthetic: Bool = false, layoutTook: Bool = false,
                      pointer: Pointer = Pointer(.other)) -> InputLatencyDispatch.Slot? {
        let slot = wiring.open(type, scrollPhase: phase, timestamp: timestamp, window: window, synthetic: synthetic,
                               keyWindow: keyWindow, underPointer: pointer.hit)
        if let slot { wiring.didDispatch(slot, layoutTookScroll: layoutTook) }
        return slot
    }

    private func window(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    // MARK: Which events open a slot

    @Test("A plain pointer move, a key up, a modifier change and other gestures open no slot")
    func untrackedEventsOpenNone() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        for type in [InputEventType.mouseMoved, .keyUp, .flagsChanged, .magnify, .rotate, .swipe, .smartMagnify, .pressure] {
            #expect(send(wiring, type) == nil, "\(type)")
        }
        #expect(harness.tracker.pendingCount == 0)
        #expect(harness.boundary.requests == 0, "no slot, no commit boundary")
    }

    @Test("A real mouseMoved NSEvent opens nothing; a real key down opens one key press")
    func realEvents() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0.5,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        #expect(wiring.willDispatch(move, synthetic: false, keyWindow: nil) == nil)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0.5,
                                                windowNumber: 0, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let slot = try #require(wiring.willDispatch(key, synthetic: false, keyWindow: nil))
        wiring.didDispatch(slot, layoutTookScroll: false)
        #expect(harness.tracker.pendingCount == 1, "exactly one slot for the key")
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress])
        #expect(harness.emitted.first?.target == .other, "no key window")
        #expect(harness.emitted.first?.reached(.dispatchEnd) == true)
    }

    @Test("A key, a click and a scroll each give one closed slot with the right kind and target")
    func keyClickScroll() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let layout = LayoutFake(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalFake(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        layout.addSubview(terminal)
        let window = window(content: layout)
        #expect(window.makeFirstResponder(terminal))

        send(wiring, .keyDown, keyWindow: window)
        let click = Pointer(.agentPane)
        send(wiring, .leftMouseDown, pointer: click)
        send(wiring, .leftMouseUp, pointer: click)
        let scroll = Pointer(.webkitPage)
        send(wiring, .scrollWheel, phase: .began, pointer: scroll)
        send(wiring, .scrollWheel, phase: .changed, pointer: scroll)
        #expect(harness.tracker.pendingCount == 5, "one slot per tracked event")
        harness.settle()

        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress, .mouseRelease, .scrollBegin, .scrollFirstUpdate])
        #expect(harness.emitted.map(\.target) == [.terminal, .agentPane, .agentPane, .webkitPage, .webkitPage])
        #expect(harness.emitted.allSatisfy { $0.entrypoint == .person && $0.reached(.dispatchEnd) })
        #expect(click.hitTests == 1, "the release lands where its press went, with no second hit test")
        #expect(scroll.hitTests == 1, "the gesture's target is found once, at its begin")
    }

    @Test("Scroll phases: began, the first update, later updates and moving momentum open slots; touch, end, cancel and the coast's end none")
    func scrollPhases() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let pointer = Pointer(.chromiumPage)
        for phase in [InputScrollPhase.mayBegin, .began, .changed, .changed, .ended, .momentum, .momentum, .momentumEnded,
                      .began, .changed, .cancelled] {
            send(wiring, .scrollWheel, phase: phase, pointer: pointer)
        }
        send(wiring, .scrollWheel, phase: .none, pointer: pointer)
        harness.settle()
        #expect(harness.emitted.map(\.kind) == [.scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum,
                                                .scrollMomentum, .scrollBegin, .scrollFirstUpdate, .scrollUpdate])
        #expect(harness.emitted.allSatisfy { $0.target == .chromiumPage })
        #expect(pointer.hitTests == 3, "one per gesture begin and one per wheel notch")
    }

    @Test("The first drag of each frame interval since the press opens a slot; later drags join it, or the next one after its turn committed")
    func dragOncePerFrame() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let pointer = Pointer(.layout)
        // Frame intervals of 10 ms count from the press at 0.505: [0.505, 0.515), [0.515, 0.525), ...
        send(wiring, .leftMouseDown, at: 0.505, pointer: pointer)
        #expect(send(wiring, .leftMouseDragged, at: 0.506, pointer: pointer)?.kind == .drag)
        harness.commit()  // a drag usually comes in its own run-loop turn, after the last one committed
        #expect(send(wiring, .leftMouseDragged, at: 0.509, pointer: pointer) == nil)
        harness.commit()
        #expect(send(wiring, .leftMouseDragged, at: 0.512, pointer: pointer) == nil, "the same interval since the press")
        harness.commit()
        #expect(send(wiring, .leftMouseDragged, at: 0.514, pointer: pointer) == nil)
        #expect(send(wiring, .leftMouseDragged, at: 0.516, pointer: pointer)?.kind == .drag, "the next frame interval")
        #expect(send(wiring, .leftMouseDragged, at: 0.518, pointer: pointer) == nil, "joins the open slot of its turn")
        send(wiring, .leftMouseUp, at: 0.519, pointer: pointer)
        send(wiring, .leftMouseDown, at: 0.520, pointer: pointer)
        #expect(send(wiring, .leftMouseDragged, at: 0.521, pointer: pointer)?.kind == .drag, "a new press starts over")
        harness.commit()

        #expect(harness.emitted.map(\.kind) == [.mousePress, .drag, .drag, .mouseRelease, .mousePress, .drag])
        #expect(harness.emitted[1].coalescedCount == 1, "its turn committed before the next drag came")
        #expect(harness.emitted[2].coalescedCount == 5,
                "itself, the three drags that came after the first slot closed, and the one of its own turn")
        #expect(harness.emitted[5].coalescedCount == 1, "a new press carries nothing over")
        #expect(harness.emitted.allSatisfy { $0.target == .layout })
        #expect(pointer.hitTests == 2, "one per press; drags and releases keep its target")
    }

    @Test("Synthetic input is labelled automation")
    func syntheticIsAutomation() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        send(wiring, .keyDown, synthetic: true)
        send(wiring, .leftMouseDown, synthetic: false)
        harness.commit()
        #expect(harness.emitted.map(\.entrypoint) == [.automation, .person])
    }

    @Test("A scroll the layout took is the layout's, and so is the rest of its gesture")
    func layoutTakesScroll() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let pointer = Pointer(.terminal)
        send(wiring, .scrollWheel, phase: .began, layoutTook: true, pointer: pointer)
        send(wiring, .scrollWheel, phase: .changed, layoutTook: true, pointer: pointer)
        send(wiring, .scrollWheel, phase: .momentum, pointer: pointer)
        send(wiring, .scrollWheel, phase: .began, pointer: pointer)
        harness.settle()
        #expect(harness.emitted.map(\.target) == [.layout, .layout, .layout, .terminal], "a new gesture is hit-tested again")
        #expect(harness.emitted.prefix(2).allSatisfy { $0.causedFrameUpdate }, "a layout scroll moved the layout")
    }

    @Test("A frame update is what the dispatch left for the commit, never the target alone; a key closes either way")
    func frameUpdates() throws {
        let unchanged = InputLatencyTrackerTests.Harness()
        unchanged.tracker.pagesReportPresentation = true  // the page waits for its own frame, as the terminal does
        let still = wiring(unchanged)
        let window = window(content: NSView())
        send(still, .keyDown, window: window, keyWindow: window)
        send(still, .leftMouseDown, window: window, pointer: Pointer(.sidebar))
        send(still, .leftMouseDown, window: window, pointer: Pointer(.terminal))
        send(still, .scrollWheel, window: window, pointer: Pointer(.chromiumPage))
        unchanged.settle()
        #expect(unchanged.emitted.map(\.kind) == [.keyPress, .mousePress, .mousePress, .scrollUpdate],
                "the key closes with no frame update")
        #expect(unchanged.emitted.allSatisfy { !$0.causedFrameUpdate },
                "a terminal or a page marks its own slot when its frame lands; its target alone is no frame")

        let changed = InputLatencyTrackerTests.Harness()
        let moving = wiring(changed, windowChanged: { $0 === window })
        send(moving, .leftMouseDown, window: window, pointer: Pointer(.sidebar))
        send(moving, .leftMouseDown, pointer: Pointer(.sidebar))
        send(moving, .leftMouseDown, window: self.window(content: NSView()), pointer: Pointer(.sidebar))
        changed.commit()
        #expect(changed.emitted.map(\.causedFrameUpdate) == [true, false, false],
                "only a click whose window holds a change for the commit")
    }

    @Test("A press whose dispatch runs a nested run loop closes at that loop's commit, a frame its input produced")
    func nestedLoopCommitIsAFrameUpdate() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        // A right click whose dispatch opens a context menu: the menu's tracking loop commits inside the dispatch.
        let slot = try #require(wiring.open(.rightMouseDown, scrollPhase: .none, timestamp: 0.5, window: nil,
                                            synthetic: false, keyWindow: nil, underPointer: Pointer(.sidebar).hit))
        harness.commit()
        wiring.didDispatch(slot, layoutTookScroll: false)
        let closed = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1)
        #expect(closed.kind == .mousePress && closed.target == .sidebar)
        #expect(closed.causedFrameUpdate, "the ledger keeps it")
        #expect(!closed.reached(.dispatchEnd), "it closed before its dispatch returned")
        #expect(harness.tracker.pendingCount == 0)

        let missed = InputLatencyTrackerTests.Harness()
        let idle = self.wiring(missed)
        let waiting = try #require(idle.open(.leftMouseDown, scrollPhase: .none, timestamp: 0.5, window: nil,
                                             synthetic: false, keyWindow: nil, underPointer: Pointer(.sidebar).hit))
        missed.commit(.missed)
        idle.didDispatch(waiting, layoutTookScroll: false)
        #expect(missed.emitted.map(\.causedFrameUpdate) == [false], "a missed commit is idle time, not a frame")
    }

    @Test("A page window's slot is presented by the cmux window that holds it; a change in either window counts")
    func ownerWindowPresents() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let owner = window(content: NSView())
        let page = window(content: NSView())
        owner.addChildWindow(page, ordered: .above)
        defer { owner.removeChildWindow(page) }
        let wiring = wiring(harness, windowChanged: { $0 === owner })
        let slot = try #require(send(wiring, .leftMouseDown, window: page, pointer: Pointer(.chromiumPage)))
        #expect(slot.window === owner, "the owner's display link and vsync, not a new link for the page window")
        #expect(slot.eventWindow === page)
        #expect(send(wiring, .leftMouseDown, window: owner, pointer: Pointer(.layout))?.window === owner)
        harness.settle()
        #expect(harness.emitted.map(\.causedFrameUpdate) == [true, true])
    }

    @Test("Real scroll events: moving momentum is momentum; the coast's end moves nothing and opens no slot")
    func realMomentumPhases() throws {
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 1, momentum: 0)) == .began)
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 2, momentum: 0)) == .changed)
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 4, momentum: 0)) == .ended)
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 0, momentum: 1)) == .momentum)
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 0, momentum: 2)) == .momentum)
        #expect(try InputEventRecord.scrollPhase(of: scrollEvent(phase: 0, momentum: 3)) == .momentumEnded)

        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let coast = try scrollEvent(phase: 0, momentum: 2)
        #expect(wiring.willDispatch(coast, synthetic: false, keyWindow: nil)?.kind == .scrollMomentum)
        let end = try scrollEvent(phase: 0, momentum: 3)
        #expect(wiring.willDispatch(end, synthetic: false, keyWindow: nil) == nil,
                "Chrome's GestureScrollEnd, not an inertial update")
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.scrollMomentum])
    }

    @Test("Key presses and scroll slots carry key.frame and key.scroll_frame, ended at the slot's commit with its target")
    func frameIntervals() {
        let recorder = FrameIntervalRecorder()
        let harness = InputLatencyTrackerTests.Harness(frameIntervals: recorder)
        let wiring = wiring(harness)
        let layout = LayoutFake(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalFake(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        layout.addSubview(terminal)
        let window = window(content: layout)
        #expect(window.makeFirstResponder(terminal))

        send(wiring, .keyDown, window: window, keyWindow: window)
        send(wiring, .leftMouseDown, pointer: Pointer(.terminal))
        send(wiring, .scrollWheel, phase: .began, layoutTook: true, pointer: Pointer(.terminal))
        send(wiring, .scrollWheel, phase: .changed, pointer: Pointer(.terminal))
        send(wiring, .scrollWheel, phase: .ended, pointer: Pointer(.terminal))
        send(wiring, .scrollWheel, phase: .none, pointer: Pointer(.webkitPage))
        #expect(recorder.ended.isEmpty, "they end at the commit")
        harness.commit()

        #expect(recorder.begun.map { $0.interval } == [.key, .scroll(.began), .scroll(.changed), .scroll(.wheel)],
                "no interval for a click or a scroll end")
        #expect(recorder.begun.first?.target == .terminal, "key.frame target=terminal")
        #expect(recorder.ended.map { $0.target } == [.terminal, .layout, .layout, .webkitPage],
                "the layout's scroll ends target=layout, the page's target=content")
        #expect(recorder.ended.allSatisfy { $0.outcome == .committed })
        #expect(InputFrameSignposts.ageMilliseconds(eventTimestamp: 10, now: 10.0125) > 12.49)
        #expect(InputFrameSignposts.ageMilliseconds(eventTimestamp: 0, now: 10) == -1)
    }

    // MARK: Classifier

    @Test("The first matching rule wins over a nearer view; text input, windows and no match")
    func classifierRules() {
        let classifier = Self.classifier()
        let layout = LayoutFake()
        let agent = AgentFake()
        let web = WebFake()
        let leaf = NSView()
        layout.addSubview(agent)
        agent.addSubview(web)
        web.addSubview(leaf)
        #expect(classifier.classify(view: leaf, in: nil) == .agentPane, "an agent pane's web view is the agent pane")
        let text = NSTextView()
        layout.addSubview(text)
        #expect(classifier.classify(view: text, in: nil) == .textView)
        let plain = NSView()
        layout.addSubview(plain)
        #expect(classifier.classify(view: plain, in: nil) == .layout)
        #expect(classifier.classify(view: NSView(), in: nil) == .other)
        let page = PageWindowFake(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        #expect(classifier.classify(view: plain, in: page) == .chromiumPage, "a page window outranks the layout")
        #expect(classifier.classify(view: nil, in: page) == .chromiumPage)
    }

    @Test("The window's field editor is classified each time; a responder moved to another surface is classified again")
    func keyTargetFollowsFieldEditorAndMoves() {
        let classifier = Self.classifier()
        let layout = LayoutFake(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalFake(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        layout.addSubview(terminal)
        let window = window(content: layout)
        // AppKit keeps the field editor inside the edited field; the field moves, the editor and its superview stay.
        let field = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let editor = NSTextView(frame: field.bounds)
        editor.isFieldEditor = true
        field.addSubview(editor)
        terminal.addSubview(field)
        #expect(window.makeFirstResponder(editor))
        #expect(classifier.keyTarget(in: window) == .terminal)
        field.removeFromSuperview()
        layout.addSubview(field)
        #expect(window.makeFirstResponder(editor))
        #expect(classifier.keyTarget(in: window) == .textView, "the same editor and superview, another surface")

        let focusable = FocusableFake(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        terminal.addSubview(focusable)
        #expect(window.makeFirstResponder(focusable))
        #expect(classifier.keyTarget(in: window) == .terminal)
        focusable.removeFromSuperview()
        layout.addSubview(focusable)
        #expect(window.makeFirstResponder(focusable))
        #expect(classifier.keyTarget(in: window) == .layout, "moved to another superview")
    }

    @Test("A page window an agent pane owns is the agent pane; other page windows stay pages; one ask per window")
    func pageWindowOwner() {
        let agentPage = PageWindowFake(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                                       backing: .buffered, defer: true)
        let browserPage = PageWindowFake(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                                         backing: .buffered, defer: true)
        agentPage.isReleasedWhenClosed = false
        browserPage.isReleasedWhenClosed = false
        var asks = 0
        let classifier = InputTargetClassifier(rules: [
            .view(TerminalFake.self, is: .terminal),
            .windowClassNamed(NSStringFromClass(PageWindowFake.self), is: .chromiumPage, owner: { window in
                asks += 1
                return window === agentPage ? .agentPane : nil
            }),
            .view(LayoutFake.self, is: .layout),
        ])
        #expect(classifier.classify(view: NSView(), in: agentPage) == .agentPane)
        #expect(classifier.classify(view: nil, in: agentPage) == .agentPane)
        #expect(asks == 1, "the answer is kept for the same window")
        #expect(classifier.classify(view: NSView(), in: browserPage) == .chromiumPage)
        #expect(classifier.classify(view: nil, in: agentPage) == .agentPane)
        #expect(asks == 3)
        #expect(classifier.classify(view: TerminalFake(), in: agentPage) == .terminal, "a more specific view rule still wins")
    }

    @Test("A named window class that loads after launch is found at its first window")
    func lateLoadedWindowClass() throws {
        let name = "CmuxNextInputTestsLateWindow\(UInt32.random(in: 0...UInt32.max))"
        let classifier = InputTargetClassifier(rules: [.windowClassNamed(name, is: .chromiumPage)])
        let plain = window(content: NSView())
        #expect(classifier.classify(view: nil, in: plain) == .other)
        #expect(classifier.classify(view: nil, in: plain) == .other, "a window of the class it missed on")
        let late: AnyClass = try #require(objc_allocateClassPair(NSWindow.self, name, 0))
        objc_registerClassPair(late)
        let page = window(content: NSView())
        _ = object_setClass(page, late)
        #expect(classifier.classify(view: nil, in: page) == .chromiumPage)
        #expect(classifier.classify(view: nil, in: plain) == .other)
    }

    @Test("A key's target follows its window's first responder")
    func keyTargetFollowsFocus() {
        let classifier = Self.classifier()
        let layout = LayoutFake(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalFake(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let text = NSTextView(frame: NSRect(x: 200, y: 0, width: 100, height: 100))
        layout.addSubview(terminal)
        layout.addSubview(text)
        let window = window(content: layout)
        #expect(classifier.keyTarget(in: nil) == .other)
        #expect(window.makeFirstResponder(terminal))
        #expect(classifier.keyTarget(in: window) == .terminal)
        #expect(classifier.keyTarget(in: window) == .terminal, "cached")
        #expect(window.makeFirstResponder(text))
        #expect(classifier.keyTarget(in: window) == .textView)
    }

    @Test("A pointer's view is AppKit's hit test in window coordinates")
    func hitTestView() {
        let layout = LayoutFake(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalFake(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        layout.addSubview(terminal)
        let window = window(content: layout)
        #expect(InputTargetClassifier.view(at: NSPoint(x: 50, y: 50), in: window) === terminal)
        #expect(Self.classifier().classify(view: InputTargetClassifier.view(at: NSPoint(x: 300, y: 200), in: window),
                                           in: window) == .layout)
    }

    // MARK: Sampling

    @Test("Sampling decisions per event type and phase")
    func samplingDecisions() {
        var sampling = InputLatencySampling()
        #expect(sampling.decide(.keyDown, scrollPhase: .none, timestamp: 1, frameInterval: 0.01) == .open(.keyPress, target: .keyboardFocus))
        #expect(sampling.decide(.rightMouseDown, scrollPhase: .none, timestamp: 1, frameInterval: 0.01) == .open(.mousePress, target: .underPointer))
        #expect(sampling.decide(.otherMouseUp, scrollPhase: .none, timestamp: 1, frameInterval: 0.01) == .open(.mouseRelease, target: .latched))
        #expect(sampling.decide(.rightMouseDragged, scrollPhase: .none, timestamp: 1.001, frameInterval: 0.01) == .open(.drag, target: .latched))
        #expect(sampling.decide(.rightMouseDragged, scrollPhase: .none, timestamp: 1.002, frameInterval: 0.01) == .coalesceDrag)
        #expect(sampling.decide(.mouseMoved, scrollPhase: .none, timestamp: 1, frameInterval: 0.01) == .skip)
        #expect(sampling.decide(.scrollWheel, scrollPhase: .none, timestamp: 1, frameInterval: 0.01) == .open(.scrollUpdate, target: .underPointer))
    }
}
