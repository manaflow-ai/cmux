import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import Foundation
import Testing

/// Audit batch 3, H6 and H15 (audit-findings-3.md, multiwindow.md): a drag's per-pointer-event window
/// pick and Cmd-` / Zoom's window choice read the app's windows front to back. On the base that is
/// `NSApp.orderedWindows`, a WindowServer query on the input path (20-37 ms wall measured on a busy
/// main thread, first-seconds evidence). The app keeps its own front-to-back record (the window
/// registry's recency, updated on every order-in and key change), which the input path reads instead.
///
/// Each case checks the order, then times its path (a few hundred rounds, well under a second) and prints
/// one `WINDOW-ORDER-BENCH {json}` line; the agent reads the numbers before and after. It asserts no time.
/// `CMUX_BENCH=1` runs ten times the rounds.
@MainActor @Suite(.serialized) struct WindowOrderInputPathBench {
    private struct World {
        let services: AppServices
        let windows: [WindowController]
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    /// Three windows on screen, overlapping, ordered in through the app's own path; window 2 in front.
    private static func world() throws -> World {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let windows = try ["wob-1", "wob-2", "wob-3"].enumerated().map { index, workspace in
            let controller = try #require(services.windows.openWindow(workspaces: [workspace]))
            let shell = try #require(controller.window)
            shell.setFrame(CGRect(x: 100 + index * 40, y: 100 + index * 40, width: 700, height: 500), display: false)
            return controller
        }
        for index in [0, 2, 1] {
            let shell = try #require(windows[index].window)
            shell.orderFrontRegardless()
            services.windows.windowDidOrder(shell, inFront: true)
        }
        return World(services: services, windows: windows)
    }

    private static var benching: Bool { ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1" }

    private static func time(_ label: String, rounds base: Int = 300, _ body: () -> Void) {
        let rounds = benching ? base * 10 : base
        for _ in 0..<20 { body() }  // warm
        var samples: [Double] = []
        samples.reserveCapacity(rounds)
        for _ in 0..<rounds {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        let pick = { (q: Double) in samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        let line: [String: Any] = ["path": label, "rounds": rounds, "p50_us": pick(0.5), "p95_us": pick(0.95),
                                   "p99_us": pick(0.99), "max_us": samples.last ?? 0]
        let json = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        print("WINDOW-ORDER-BENCH \(json)")
    }

    /// H6: the window under a drag point, as each pointer event of a tab drag picks it.
    @Test func aTabDragPicksTheFrontWindowAtThePoint() throws {
        let world = try Self.world()
        defer { world.close() }
        let drag = world.services.dragSession
        let overlap = CGPoint(x: 200 + 40, y: 200 + 40)
        let picked = TabDragWindowPick.frontmost(at: overlap, in: drag.windowOrder(ghost: nil))
        Self.time("tab-drag-window-order") { _ = TabDragWindowPick.frontmost(at: overlap, in: drag.windowOrder(ghost: nil)) }
        #expect(picked == world.windows[1].state.id, "the drag picked \(picked ?? "no window") over the front window 2")
    }

    /// H15: Select Next Window (Cmd-`) and Zoom pick their window from the windows front to back.
    @Test func selectNextWindowCyclesFromTheFrontWindow() throws {
        let world = try Self.world()
        defer { world.close() }
        let registry = world.services.registry
        AppActions.bind(world.services)
        let shell2 = world.windows[1].window
        world.services.keyWindowSource = { shell2 }
        world.services.windows.didActivate(world.windows[1])
        var shown: NSWindow?
        let previous = WindowActivation.didOrder
        WindowActivation.didOrder = { window, inFront in shown = window; previous?(window, inFront) }
        defer { WindowActivation.didOrder = previous }
        world.services.windows.dispatching(eventFrom: shell2) { _ = registry.perform("selectNextWindow") }
        // From window 2 (front), the next window front to back is window 3.
        #expect(shown === world.windows[2].window, "Select Next Window from window 2 showed \(shown.map { "\($0.windowNumber)" } ?? "nothing")")
        Self.time("select-next-window", rounds: 100) {
            world.services.windows.dispatching(eventFrom: shell2) { _ = registry.perform("selectNextWindow") }
        }
    }
}
