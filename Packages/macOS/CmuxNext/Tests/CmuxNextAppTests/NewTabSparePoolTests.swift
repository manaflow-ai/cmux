import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextMemory
import Foundation
import Testing

/// The New Tab spare's next warm waits for quiet input through the app's input tap (p04-input-012):
/// a key-down pushes it back by the quiet period, a key-up does not, and the warm drops the
/// subscription. The warm is a background-class ``MainDeadline`` (p06-scheduler-309): the rig fires it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSparePoolTests {
    @Test func aKeyDownPushesTheWarmBackAndAKeyUpDoesNot() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-input")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let rig = MainDeadlineRig()
            let pool = NewTabSparePool(services: services, memory: services.memoryCoordinator, input: tap, deadlines: rig.deadlines)
            pool.webKit.markSlow() // the warm makes no web view: this test is about when it runs
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            pool.retarget(window) // the launch warm, 250 ms out
            #expect(tap.liveSubscriptions == 1)
            #expect(tap.classes == [.key, .button, .scroll])
            rig.advance(by: .milliseconds(200))
            tap.deliver(InputEventRecord(type: .keyDown, timestamp: 1)) // the warm moves to 950 ms
            rig.advance(by: .milliseconds(100))
            #expect(tap.liveSubscriptions == 1, "the key-down pushed the 250 ms warm back")
            tap.deliver(InputEventRecord(type: .keyUp, timestamp: 2)) // a re-arm here would move it to 1050 ms
            rig.fireAndRun()
            #expect(tap.liveSubscriptions == 0, "the warm ran and dropped the subscription")
            #expect(rig.elapsed >= 0.95 && rig.elapsed < 1.0, "the warm ran at \(rig.elapsed) s, not 950 ms")
        }
    }

    /// p06-scheduler-309: the spare follows its window's close through that window's one observer
    /// (WindowEvents), not an app-wide one: a closing target hands the spare to another visible main window.
    @Test func theSpareMovesToAnotherWindowWhenItsWindowCloses() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-close")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pool = NewTabSparePool(services: services, memory: services.memoryCoordinator, input: FakeInputTap(),
                                       deadlines: MainDeadlineRig().deadlines)
            pool.webKit.markSlow() // the warm makes no web view: this test is about where the spare parks
            let main = try #require(services.windows.active?.window)
            main.setIsVisible(true)
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                 backing: .buffered, defer: true)
            other.isReleasedWhenClosed = false
            pool.retarget(other)
            #expect(pool.target === other)
            other.close()
            #expect(pool.target === main, "the spare stayed with its closed window")
        }
    }

    /// p08-startup-017: the launch posts the hooks after the first frame and the warm at afterStartup.
    @Test func aHeldStartMakesNoSpareUntilWarmingStarts() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-hooks")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let pool = NewTabSparePool(services: services, memory: services.memoryCoordinator, input: tap, deadlines: MainDeadlineRig().deadlines)
            pool.webKit.markSlow() // the warm makes no web view: this test is about when it is armed
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            pool.start(holdingWarm: true)
            #expect(services.agentTabs.takeSpare != nil, "Cmd-T and Cmd-N find the hooks")
            pool.retarget(window)
            #expect(pool.target === window, "the spare's window is known")
            #expect(tap.liveSubscriptions == 0, "no warm is armed before startWarming")
            pool.startWarming()
            #expect(tap.liveSubscriptions == 1, "the launch warm is armed")
        }
    }

    /// p07-memory-047, Chrome's spare rule: in the default (medium) Memory Saver mode at normal
    /// pressure the pool keeps its spare and arms its warm; a warning cancels the armed warm and
    /// arms none, a take arms no refill, and back at normal the warm is armed again.
    @Test func noWarmUnderPressureAndTheWarmReturnsAtNormal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-pressure")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let kernel = ManualMemoryPressureSource()
            let pressure = MemoryPressureEvents(source: kernel)
            let memory = MemoryCoordinator(pressure: pressure, mode: .medium, slicer: BrowserHibernationPressureTests.HeldSlices())
            let tap = FakeInputTap()
            let pool = NewTabSparePool(services: services, memory: memory, input: tap, deadlines: MainDeadlineRig().deadlines)
            pool.webKit.markSlow() // the warm makes no web view: this test is about when it is armed
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            pool.retarget(window)
            #expect(pool.allowsSpare, "medium mode at normal must keep one spare")
            #expect(tap.liveSubscriptions == 1, "medium mode at normal arms the warm")

            kernel.send(.warning)
            #expect(!pool.allowsSpare)
            #expect(tap.liveSubscriptions == 0, "a warning must cancel the armed warm")
            #expect(pool.spareView == nil)
            _ = pool.take(for: window, size: nil)
            #expect(tap.liveSubscriptions == 0, "a take at warning armed a refill")

            kernel.send(.critical)
            #expect(tap.liveSubscriptions == 0, "a warm was armed at critical")

            kernel.send(.normal)
            #expect(pool.allowsSpare)
            #expect(tap.liveSubscriptions == 1, "back at normal the warm is armed again")
            withExtendedLifetime(pressure) {}
        }
    }
}
