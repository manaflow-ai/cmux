import AppKit
import CmuxNextActions
import CmuxNextInput
@testable import CmuxNextApp
import Foundation
import Testing

/// Lawrence 2026-10-28: "if i hold cmd t then stop holding it, it still creates new stuff for a while ... same with
/// ctrl+`" (repeat-runoff.md 1, hold-shortcuts-ux.md 1). Key repeat is a real input stream: a held shortcut acts once
/// per repeat event the system delivers while the key is down, never on a backlog of repeats that waited in the queue
/// while the main thread was busy, so nothing happens after the key goes up. A physical press always acts, at any
/// speed (input-principles.md). Each key goes through the real dispatcher (`KeyRouter.interceptKeyDown`) of the app
/// on a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct KeyRepeatRunoffTests {
    /// A shortcut of the shortcut-spam list and the action its default key runs.
    nonisolated struct Shortcut: Sendable, CustomTestStringConvertible {
        var name: String
        var characters: String
        var keyCode: UInt16
        var command: Bool
        var action: String
        var testDescription: String { name }

        static let cmdT = Shortcut(name: "Cmd-T", characters: "t", keyCode: 17, command: true, action: "newTab.default")
        static let ctrlBacktick = Shortcut(name: "Ctrl-`", characters: "`", keyCode: 50, command: false, action: "newSurface")
        static let cmdN = Shortcut(name: "Cmd-N", characters: "n", keyCode: 45, command: true, action: "newTab")
        static let cmdD = Shortcut(name: "Cmd-D", characters: "d", keyCode: 2, command: true, action: "splitRight")
        static let cmdW = Shortcut(name: "Cmd-W", characters: "w", keyCode: 13, command: true, action: "closeTab")
        static let ctrlTab = Shortcut(name: "Ctrl-Tab", characters: "\t", keyCode: 48, command: false, action: "nextSurface")
        static let all: [Shortcut] = [.cmdT, .ctrlBacktick, .cmdN, .cmdD, .cmdW, .ctrlTab]
    }

    /// The main thread was busy for 2 s while the key was held; the key went up 100 ms ago. Every repeat still in the
    /// queue is older than one repeat interval: none of them runs its action (before: each ran, after the key-up).
    @Test(arguments: Shortcut.all)
    func aBacklogOfRepeatsRunsNothingAfterTheKeyUp(_ shortcut: Shortcut) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(shortcut, services: services, window: window)
            let runs = Self.countRuns(of: shortcut.action, services)
            // Worst case: the key state still reads down (the key-up has not reached the system yet); only the
            // repeats' age shows they are a backlog.
            services.keyRouter.repeats.keyIsDown = { _ in true }
            services.keyRouter.repeats.repeatInterval = { 0.033 } // the fastest System Settings rate
            let now = ProcessInfo.processInfo.systemUptime
            let keyUp = now - 0.1
            var time = now - 2.0 + 0.5 // after the system's initial repeat delay
            var delivered = 0
            while time < keyUp {
                Self.dispatch(Self.event(shortcut, at: time, isRepeat: true, window: window), services: services, window: window)
                delivered += 1
                time += 0.033
            }
            try #require(delivered > 40)
            #expect(runs.count == 0, "\(shortcut.name): \(runs.count) of \(delivered) stale repeats ran after the key went up")
        }
    }

    /// A physical press always acts, however long it waited (fast presses all count).
    @Test func aPhysicalPressRunsHoweverLongItWaited() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            let old = ProcessInfo.processInfo.systemUptime - 1.5
            for index in 0..<5 {
                Self.dispatch(Self.event(.ctrlTab, at: old + Double(index) * 0.001, isRepeat: false, window: window), services: services, window: window)
            }
            #expect(runs.count == 5, "\(runs.count) of 5 physical presses ran")
        }
    }

    /// A held key whose repeats arrive on time (the main thread keeps up): one action per repeat, none dropped.
    @Test func aHeldKeyRunsOncePerRepeatDeliveredOnTime() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            services.keyRouter.repeats.keyIsDown = { _ in true }
            services.keyRouter.repeats.repeatInterval = { 0.033 } // the fastest System Settings rate
            for _ in 0..<12 {
                let now = ProcessInfo.processInfo.systemUptime
                Self.dispatch(Self.event(.ctrlTab, at: now, isRepeat: true, window: window), services: services, window: window)
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(runs.count == 12, "\(runs.count) of 12 on-time repeats ran")
        }
    }

    /// At most one repeat action per display frame per key: two repeats of one key in the same frame act once.
    @Test func twoRepeatsInOneFrameActOnce() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            services.keyRouter.repeats.keyIsDown = { _ in true }
            services.keyRouter.repeats.repeatInterval = { 0.033 } // the fastest System Settings rate
            let now = ProcessInfo.processInfo.systemUptime
            Self.dispatch(Self.event(.ctrlTab, at: now, isRepeat: true, window: window), services: services, window: window)
            Self.dispatch(Self.event(.ctrlTab, at: now + 0.0005, isRepeat: true, window: window), services: services, window: window)
            #expect(runs.count == 1, "\(runs.count) repeat actions in one frame")
        }
    }

    /// The brief's check (repeat-runoff.md 1): hold the key 2 s, then release. Repeats are made every 33 ms on the
    /// system's clock whatever the main thread does; a repeat made while the main thread was busy waits, as in the
    /// event queue. Nothing runs more than one frame after the key-up, and the items made are the repeats delivered
    /// while the key was down (the physical press included), within one.
    @Test(arguments: [Shortcut.cmdT, .ctrlBacktick, .ctrlTab])
    func holdTwoSecondsThenReleaseRunsNothingAfterTheKeyUp(_ shortcut: Shortcut) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(shortcut, services: services, window: window)
            let runs = Self.countRuns(of: shortcut.action, services)
            let start = ProcessInfo.processInfo.systemUptime
            let keyUp = start + 2.0, frame = 1.0 / 60
            // The system's key state: down until the key-up.
            services.keyRouter.repeats.keyIsDown = { _ in ProcessInfo.processInfo.systemUptime < keyUp }
            services.keyRouter.repeats.repeatInterval = { 0.033 } // the fastest System Settings rate
            var deliveredWhileDown = 0
            var lateRuns = 0
            var index = 0
            while true {
                let made = start + (index == 0 ? 0 : 0.5 + Double(index - 1) * 0.033)
                guard made < keyUp else { break }
                var now = ProcessInfo.processInfo.systemUptime
                if now < made {
                    try await Task.sleep(for: .milliseconds(Int(((made - now) * 1000).rounded(.up))))
                    now = ProcessInfo.processInfo.systemUptime
                }
                if now < keyUp { deliveredWhileDown += 1 }
                let before = runs.count
                Self.dispatch(Self.event(shortcut, at: made, isRepeat: index > 0, window: window), services: services, window: window)
                if runs.count > before, now > keyUp + frame { lateRuns += 1 }
                index += 1
                // The main thread's other work between events (frames, replies) runs here, as in the app.
                await Task.yield()
            }
            print("hold-2s \(shortcut.name): \(index) repeats made, \(deliveredWhileDown) delivered while down, \(runs.count) ran, \(lateRuns) after the key-up")
            #expect(lateRuns == 0, "\(shortcut.name): \(lateRuns) actions ran more than one frame after the key-up")
            #expect(runs.count >= 1, "\(shortcut.name): the physical press did not run")
            #expect(runs.count <= deliveredWhileDown + 1, "\(shortcut.name): \(runs.count) actions for \(deliveredWhileDown) keys delivered while down")
        }
    }

    // MARK: Helpers

    @MainActor final class Runs {
        var count = 0
    }

    /// Counts the runs of `action` from now on (the registry's will-run notice, refused runs included).
    static func countRuns(of action: String, _ services: AppServices) -> Runs {
        let runs = Runs()
        services.registry.willRunObservers.append { [weak runs] id, _ in
            if id.rawValue == action { runs?.count += 1 }
        }
        return runs
    }

    static func event(_ shortcut: Shortcut, at time: TimeInterval, isRepeat: Bool, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.command ? .command : .control, timestamp: time,
                         windowNumber: window.windowNumber, context: nil, characters: shortcut.characters,
                         charactersIgnoringModifiers: shortcut.characters, isARepeat: isRepeat, keyCode: shortcut.keyCode)!
    }

    /// The key-down as `CmuxApplication.sendEvent` dispatches it.
    static func dispatch(_ event: NSEvent, services: AppServices, window: NSWindow) {
        let router = services.keyRouter
        _ = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
    }

    /// The shortcut's default key runs its action here (else a red would test nothing).
    static func requireBinding(_ shortcut: Shortcut, services: AppServices, window: NSWindow) throws {
        let probe = event(shortcut, at: ProcessInfo.processInfo.systemUptime, isRepeat: false, window: window)
        let resolved = try #require(services.registry.resolveShortcut(for: probe), "\(shortcut.name) is bound to nothing")
        try #require(resolved.id.rawValue == shortcut.action, "\(shortcut.name) runs \(resolved.id.rawValue), not \(shortcut.action)")
    }
}
