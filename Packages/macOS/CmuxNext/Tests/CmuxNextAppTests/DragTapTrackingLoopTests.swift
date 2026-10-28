import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Foundation
import Testing

/// The drag sessions moved from AppKit local monitors to input tap intercepts. A
/// local monitor hears only the events `-[NSApplication sendEvent:]` dispatches: a release that a
/// nested tracking loop (a button's, a menu's) dequeues itself never reaches it (Apple's
/// `addLocalMonitorForEvents(matching:handler:)` documentation). The tap runs inside the same
/// `sendEvent`, so it must hear exactly the same events: the release a button's loop takes reaches
/// neither, and a drag whose release was taken that way ends at the next press, as it did.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DragTapTrackingLoopTests {
    /// What the tap and the reference monitor heard: a class, so handlers share it without a local `var`.
    final class Log {
        var tap: [NSEvent.EventType] = []
        var monitor: [NSEvent.EventType] = []
    }

    /// A press on a push button, sent through `CmuxApplication.dispatchThroughTap` (the stages
    /// `CmuxApplication.sendEvent` runs around AppKit) with AppKit's own `sendEvent`, and its release
    /// queued for the button's tracking loop: a drag-order intercept and a local monitor both hear the
    /// press only.
    @Test func aReleaseAButtonTrackingLoopTakesReachesNeitherTheTapNorALocalMonitor() throws {
        let fixture = ButtonWindow()
        defer { fixture.close() }
        let tap = InputEventTap()
        let log = Log()
        let intercept = tap.subscribe(class: .button, phase: .intercept(order: .dragSession)) { event in
            log.tap.append(event.type)
            return .pass
        }
        // input-monitor-allow: the reference the tap must match (the old drag sessions' monitor kind)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            log.monitor.append(event.type)
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        try fixture.queueRelease()
        let result = CmuxApplication.dispatchThroughTap(try fixture.event(.leftMouseDown), tap: tap) { NSApp.sendEvent($0) }

        #expect(result == .pass)
        #expect(fixture.target.clicks == 1, "the button's tracking loop did not take the queued release")
        #expect(log.tap == [.leftMouseDown], "the tap heard \(log.tap)")
        #expect(log.monitor == log.tap, "the tap heard \(log.tap), a local monitor \(log.monitor)")
        withExtendedLifetime(intercept) {}
    }

    /// A drag whose release a nested tracking loop took stays alive (its intercept never heard the
    /// release, as the monitor never did), and ends at the next press with nothing dropped; that press
    /// still reaches what it hit. The tap's intercepts are back to the count before the drag.
    @Test func aDragWhoseReleaseALoopTookEndsAtTheNextPressAsBefore() throws {
        let fixture = ButtonWindow()
        defer { fixture.close() }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tap = services.inputTap
        let session = services.linkDrags
        let base = tap.interceptCounts
        let url = URL(fileURLWithPath: "/tmp/cmux-drag-tap-tracking-loop.md")
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        #expect(tap.interceptCounts != base, "the drag installed no intercept")

        // A tracking loop inside another dispatch takes the release: no `sendEvent`, no tap.
        try fixture.queueRelease()
        fixture.button.mouseDown(with: try fixture.event(.leftMouseDown))
        #expect(fixture.target.clicks == 1, "the button's tracking loop did not take the queued release")
        #expect(session.isDragging, "the drag heard a release that never went through sendEvent")

        // The next press ends the drag and goes on to the button.
        try fixture.queueRelease()
        let result = tap.send(try fixture.event(.leftMouseDown)) { NSApp.sendEvent($0) }
        #expect(result == .pass, "the drag kept the press from what it hit")
        #expect(!session.isDragging)
        #expect(fixture.target.clicks == 2, "the press after the lost release did not reach the button")
        #expect(tap.interceptCounts == base, "the drag left an intercept: \(tap.interceptCounts) after, \(base) before")
    }
}

/// A borderless window with one push button that counts its clicks, on screen.
@MainActor
final class ButtonWindow {
    /// The button's target.
    final class Target: NSObject {
        var clicks = 0
        @objc func click(_ sender: Any?) { clicks += 1 }
    }

    /// Takes the first click of a window that is not key (a test app is never active).
    final class FirstClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 240, height: 120), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let button = FirstClickButton(frame: NSRect(x: 20, y: 40, width: 160, height: 32))
    let target = Target()

    init() {
        _ = NSApplication.shared
        window.isReleasedWhenClosed = false
        button.bezelStyle = .push
        button.target = target
        button.action = #selector(Target.click(_:))
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
    }

    /// A left mouse event at the button's center.
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// Queues the release the button's tracking loop dequeues itself (it never goes through `sendEvent`).
    func queueRelease() throws {
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
    }

    func close() {
        // A release no loop took stays queued: drop it.
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
        window.orderOut(nil)
    }
}

/// The events the drag session tests send.
@MainActor
struct DragEvents {
    /// A screen point inside no window: a drag there has no target.
    static let offScreen = CGPoint(x: -20_000, y: -20_000)

    /// A left mouse event with no window, so its location is the screen point `point`.
    static func mouse(_ type: NSEvent.EventType, at point: CGPoint = offScreen) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1,
                                               pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// A key-down with no window: Escape (key code 53) or another key.
    static func key(_ keyCode: UInt16 = 53, _ characters: String = "\u{1b}") throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: keyCode))
    }
}

extension InputEventTap {
    /// Sends `event` through the tap in one dispatch scope: observers, then the production stages around
    /// AppKit (`CmuxApplication.dispatchThroughTap`: intercepts, `superSend` unless one consumed it,
    /// after-dispatch observers). `superSend` stands in for `-[NSApplication sendEvent:]`.
    @discardableResult
    func send(_ event: NSEvent, superSend: (NSEvent) -> Void = { _ in }) -> InterceptResult {
        var result = InterceptResult.pass
        dispatching {
            deliverObserve(event)
            result = CmuxApplication.dispatchThroughTap(event, tap: self, superSend: superSend)
        }
        return result
    }

    /// The live intercepts of every event class, in `InputEventClass` order.
    var interceptCounts: [Int] { InputEventClass.allCases.map { subscriberCount($0, stage: .intercept) } }
}
