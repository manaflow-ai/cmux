import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextInput
@testable import CmuxNextApp
import Foundation
import Testing

/// Lawrence 2026-10-28: "if i hold cmd t then stop holding it, it still creates new stuff for a while ... same with
/// ctrl+`" (repeat-runoff.md 1, hold-shortcuts-ux.md 1). Key repeat is a real input stream: a held shortcut acts once
/// per repeat event the system delivers while the key is down, never on a backlog of repeats that waited in the queue
/// while the main thread was busy, so nothing happens after the key goes up. A physical press always acts, at any
/// speed (input-principles.md). Each key goes through the real dispatcher (`KeyRouter.interceptKeyDown`, inside an
/// input dispatch as `CmuxApplication.sendEvent` opens one) of the app on a same-tree cmux-tui daemon. The gate's clock
/// and key state are a virtual clock here, so the main thread's real speed on the test Mac changes no result.
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

    /// The gate's clock and the system's key state, as a test drives them.
    @MainActor final class Virtual {
        var now: TimeInterval = 10_000
        var keyUp: TimeInterval = .infinity
        var down: Bool { now < keyUp }
    }

    static let interval: TimeInterval = 0.033 // the fastest System Settings repeat rate

    static func install(_ virtual: Virtual, _ services: AppServices) {
        services.keyRouter.repeats.now = { virtual.now }
        services.keyRouter.repeats.keyIsDown = { _, _ in virtual.down }
        services.keyRouter.repeats.repeatInterval = { interval }
    }

    /// The main thread was busy for 2 s while the key was held; the key went up 100 ms ago. Every repeat still in the
    /// queue is older than one repeat interval: none runs its action. Even with the key state still reading down (the
    /// key-up not seen yet), the age alone stops them.
    @Test(arguments: Shortcut.all)
    func aBacklogOfRepeatsRunsNothingAfterTheKeyUp(_ shortcut: Shortcut) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(shortcut, services: services, window: window)
            let virtual = Virtual()
            Self.install(virtual, services)
            let runs = Self.countRuns(of: shortcut.action, services)
            let start = virtual.now
            virtual.now = start + 2.1
            var delivered = 0
            var made = start + 0.5
            while made < start + 2.0 {
                Self.dispatch(Self.event(shortcut, at: made, isRepeat: true, window: window), services: services, window: window)
                delivered += 1
                made += Self.interval
            }
            try #require(delivered > 40)
            #expect(runs.count == 0, "\(shortcut.name): \(runs.count) of \(delivered) stale repeats ran after the key went up")
        }
    }

    /// A fresh repeat of a key that is up (its key-up raced the repeat) runs nothing.
    @Test func aRepeatOfAKeyThatIsUpRunsNothing() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            virtual.keyUp = virtual.now - 0.001
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            Self.dispatch(Self.event(.ctrlTab, at: virtual.now, isRepeat: true, window: window), services: services, window: window)
            #expect(runs.count == 0, "a repeat after the key-up ran")
        }
    }

    /// A physical press always acts, however long it waited (fast presses all count).
    @Test func aPhysicalPressRunsHoweverLongItWaited() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            virtual.keyUp = virtual.now - 1
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            for index in 0..<5 {
                Self.dispatch(Self.event(.ctrlTab, at: virtual.now - 1.5 + Double(index) * 0.001, isRepeat: false, window: window),
                              services: services, window: window)
            }
            #expect(runs.count == 5, "\(runs.count) of 5 physical presses ran")
        }
    }

    /// A held key whose repeats arrive on time: one action per repeat, none dropped.
    @Test func aHeldKeyRunsOncePerRepeatDeliveredOnTime() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            for _ in 0..<12 {
                virtual.now += Self.interval
                Self.dispatch(Self.event(.ctrlTab, at: virtual.now - 0.002, isRepeat: true, window: window), services: services, window: window)
            }
            #expect(runs.count == 12, "\(runs.count) of 12 on-time repeats ran")
        }
    }

    /// At most one repeat action per display frame per key: two repeats of one key in the same frame act once.
    @Test func twoRepeatsInOneFrameActOnce() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(.ctrlTab, services: services, window: window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            Self.dispatch(Self.event(.ctrlTab, at: virtual.now, isRepeat: true, window: window), services: services, window: window)
            virtual.now += 0.002
            Self.dispatch(Self.event(.ctrlTab, at: virtual.now, isRepeat: true, window: window), services: services, window: window)
            #expect(runs.count == 1, "\(runs.count) repeat actions in one frame")
        }
    }

    /// Every entrypoint is gated, not only the key router's table: a stale repeat dispatching a menu key equivalent
    /// (the registry run a menu item makes) runs nothing; an action a gated run performs inside the same dispatch runs.
    @Test func aStaleRepeatRunsNothingThroughTheMenuPathEither() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            let runs = Self.countRuns(of: Shortcut.ctrlTab.action, services)
            let stale = Self.event(.ctrlTab, at: virtual.now - 1, isRepeat: true, window: window)
            _ = services.keyRouter.dispatchingSynthetic(stale) {
                services.registry.perform("nextSurface", invocation: ActionInvocation(origin: .user))
            }
            #expect(runs.count == 0, "a stale repeat ran an action through the registry")
            let fresh = Self.event(.ctrlTab, at: virtual.now, isRepeat: true, window: window)
            _ = services.keyRouter.dispatchingSynthetic(fresh) {
                services.registry.perform("nextSurface", invocation: ActionInvocation(origin: .user))
                services.registry.perform("nextSurface", invocation: ActionInvocation(origin: .user))
            }
            #expect(runs.count == 2, "one dispatch's nested runs got \(runs.count) runs, not 2")
        }
    }

    /// The brief's check (repeat-runoff.md 1): hold the key 2 s, then release. Repeats are made every 33 ms whatever the
    /// main thread does; each run of the action costs 50 ms of main-thread time (more than the repeat interval, as a
    /// create did), so repeats wait in the queue. Nothing runs more than one frame after the key-up, and the actions that
    /// ran are at most the repeats delivered while the key was down (the press included).
    @Test(arguments: [Shortcut.cmdT, .ctrlBacktick, .ctrlTab])
    func holdTwoSecondsThenReleaseRunsNothingAfterTheKeyUp(_ shortcut: Shortcut) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active?.window)
            try Self.requireBinding(shortcut, services: services, window: window)
            try await Self.secondTab(services, connection)
            let virtual = Virtual()
            Self.install(virtual, services)
            let runs = Self.countRuns(of: shortcut.action, services)
            let start = virtual.now, frame = 1.0 / 60, cost = 0.050
            virtual.keyUp = start + 2.0
            var made: [TimeInterval] = [start]
            var next = start + 0.5
            while next < virtual.keyUp { made.append(next); next += Self.interval }
            var deliveredWhileDown = 0, lateRuns = 0
            for (index, time) in made.enumerated() {
                // The main thread takes the next event when it is free and the event exists.
                virtual.now = max(virtual.now, time)
                if virtual.down { deliveredWhileDown += 1 }
                let before = runs.count
                Self.dispatch(Self.event(shortcut, at: time, isRepeat: index > 0, window: window), services: services, window: window)
                if runs.count > before {
                    if virtual.now > virtual.keyUp + frame { lateRuns += 1 }
                    virtual.now += cost
                }
                await Task.yield()
            }
            print("hold-2s \(shortcut.name): \(made.count) keys made, \(deliveredWhileDown) delivered while down, \(runs.count) ran, \(lateRuns) after the key-up")
            #expect(lateRuns == 0, "\(shortcut.name): \(lateRuns) actions ran more than one frame after the key-up")
            #expect(runs.count >= 2, "\(shortcut.name): the held key ran \(runs.count) times")
            #expect(runs.count <= deliveredWhileDown + 1, "\(shortcut.name): \(runs.count) actions for \(deliveredWhileDown) keys delivered while down")
        }
    }

    // MARK: Helpers

    /// A second tab in the focused pane, so Next Tab (Ctrl-Tab) has somewhere to go.
    static func secondTab(_ services: AppServices, _ connection: DaemonConnection) async throws {
        let pane = try #require(services.windows.active?.focusedPane)
        let surface = try await connection.newTab(in: pane.pane.handle).surface
        try await PinnedPageTests.until({ pane.orderedIDs.contains { $0.rawValue == services.daemon.store.tab(surface: surface)?.id } },
                                        report: { "the second tab never reached the strip" })
    }

    @MainActor final class Runs {
        var count = 0
    }

    /// Counts the runs of `action` from now on (the registry's will-run notice).
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
