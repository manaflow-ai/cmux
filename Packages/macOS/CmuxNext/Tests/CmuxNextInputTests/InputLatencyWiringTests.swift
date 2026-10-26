import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// The input latency wiring of `sendEvent` (p04-input-005): which events open a slot and as what kind, where they
/// land, the layout's scroll take, synthetic input, frame updates, and drags once per frame. Slots close through
/// ``InputLatencyTrackerTests/Harness``'s fake commit boundary.
@MainActor
struct InputLatencyWiringTests {
    final class TerminalFake: NSView {
        override var acceptsFirstResponder: Bool { true }
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

    private func wiring(_ harness: InputLatencyTrackerTests.Harness, windowChanged: Bool = false) -> InputLatencyDispatch {
        InputLatencyDispatch(tracker: harness.tracker, classifier: Self.classifier(), frameInterval: { _ in 0.01 },
                             windowChanged: { _ in windowChanged })
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
        #expect(harness.boundaryRequests == 0, "no slot, no commit boundary")
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
        harness.commit()

        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress, .mouseRelease, .scrollBegin, .scrollFirstUpdate])
        #expect(harness.emitted.map(\.target) == [.terminal, .agentPane, .agentPane, .webkitPage, .webkitPage])
        #expect(harness.emitted.allSatisfy { $0.entrypoint == .person && $0.reached(.dispatchEnd) })
        #expect(click.hitTests == 1, "the release lands where its press went, with no second hit test")
        #expect(scroll.hitTests == 1, "the gesture's target is found once, at its begin")
    }

    @Test("Scroll phases: began, the first update, later updates and momentum open slots; touch, end and cancel none")
    func scrollPhases() {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let pointer = Pointer(.chromiumPage)
        for phase in [InputScrollPhase.mayBegin, .began, .changed, .changed, .ended, .momentum, .momentum, .began, .changed, .cancelled] {
            send(wiring, .scrollWheel, phase: phase, pointer: pointer)
        }
        send(wiring, .scrollWheel, phase: .none, pointer: pointer)
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum,
                                                .scrollMomentum, .scrollBegin, .scrollFirstUpdate, .scrollUpdate])
        #expect(harness.emitted.allSatisfy { $0.target == .chromiumPage })
        #expect(pointer.hitTests == 3, "one per gesture begin and one per wheel notch")
    }

    @Test("The first drag of each frame opens a slot; later drags of that frame join it; a new press starts over")
    func dragOncePerFrame() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let wiring = wiring(harness)
        let pointer = Pointer(.layout)
        send(wiring, .leftMouseDown, at: 0.500, pointer: pointer)
        let first = send(wiring, .leftMouseDragged, at: 0.501, pointer: pointer)
        #expect(first?.kind == .drag)
        #expect(send(wiring, .leftMouseDragged, at: 0.503, pointer: pointer) == nil)
        #expect(send(wiring, .leftMouseDragged, at: 0.506, pointer: pointer) == nil)
        #expect(send(wiring, .leftMouseDragged, at: 0.512, pointer: pointer)?.kind == .drag, "the next frame interval")
        send(wiring, .leftMouseUp, at: 0.513, pointer: pointer)
        send(wiring, .leftMouseDown, at: 0.514, pointer: pointer)
        #expect(send(wiring, .leftMouseDragged, at: 0.515, pointer: pointer)?.kind == .drag, "a new press, same interval")
        harness.commit()

        #expect(harness.emitted.map(\.kind) == [.mousePress, .drag, .drag, .mouseRelease, .mousePress, .drag])
        #expect(harness.emitted[1].coalescedCount == 3, "the frame's first drag and the two that joined it")
        #expect(harness.emitted[2].coalescedCount == 1)
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
        harness.commit()
        #expect(harness.emitted.map(\.target) == [.layout, .layout, .layout, .terminal], "a new gesture is hit-tested again")
        #expect(harness.emitted.prefix(2).allSatisfy(\.causedFrameUpdate), "a layout scroll moved the layout")
    }

    @Test("A key with no visible change still closes as a key; a click is marked by what its dispatch changed")
    func frameUpdates() throws {
        let unchanged = InputLatencyTrackerTests.Harness()
        let still = wiring(unchanged)
        let window = window(content: NSView())
        send(still, .keyDown, window: window, keyWindow: window)
        send(still, .leftMouseDown, window: window, pointer: Pointer(.sidebar))
        send(still, .leftMouseDown, window: window, pointer: Pointer(.terminal))
        unchanged.commit()
        #expect(unchanged.emitted.map(\.kind) == [.keyPress, .mousePress, .mousePress], "the key closes with no frame update")
        #expect(unchanged.emitted.map(\.causedFrameUpdate) == [false, false, true],
                "a terminal draws outside AppKit's display pass, so its input counts as a frame update")

        let changed = InputLatencyTrackerTests.Harness()
        let moving = wiring(changed, windowChanged: true)
        send(moving, .leftMouseDown, window: window, pointer: Pointer(.sidebar))
        send(moving, .leftMouseDown, pointer: Pointer(.sidebar))
        changed.commit()
        #expect(changed.emitted.map(\.causedFrameUpdate) == [true, false], "a window-less click changed no window")
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
