import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Darwin
import Foundation
import QuartzCore

/// A window over `total` workspaces split evenly across `spaces` rooms (pins), driven through the
/// app's real space switch (`WindowManager.switchProfile`), for the space switch cost tests and the
/// baseline numbers in BASELINE.md. One switch is timed from the intent until the sidebar lists the
/// new space and the window has laid out and drawn it.
@MainActor
final class SpaceSwitchBench {
    struct Sample {
        /// Main-thread CPU time of the whole switch (intent, observation turns, layout, display), ms.
        var cpuMs: Double
        /// Wall time from the intent to the drawn window, ms.
        var wallMs: Double
        /// Time inside `switchProfile` itself, ms.
        var syncMs: Double
        /// Time of the window's layout and display pass after the switch, ms.
        var drawMs: Double
        /// Sidebar and layout counter deltas of the switch.
        var counters: [String: Int]
    }

    let services: AppServices
    let state: WindowState
    let controller: WindowController
    let rooms: [ProfileID]
    let keysByRoom: [ProfileID: [String]]

    /// - Parameters:
    ///   - total: workspaces in the window, split evenly across `spaces` rooms.
    ///   - panes: each workspace holds one pane with a terminal tab (shown) and a browser tab.
    ///   - parked: workspaces visited once before the timed switches, so they stay mounted and
    ///     parked as in a long-running window (`WindowController.park`).
    init(total: Int, spaces: Int = 2, panes: Bool = false, parked: Int = 0) async throws {
        _ = NSApplication.shared
        let i0 = CACurrentMediaTime()
        defer { print(String(format: "SPACE-SWITCH-DIAG init n=%d total=%.0fms", total, (CACurrentMediaTime() - i0) * 1000)) }
        services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let rooms = (0..<spaces).map { ProfileID(rawValue: "room\($0)") }
        let keys = (0..<total).map { "k\($0)" }
        var byRoom: [ProfileID: [String]] = [:]
        for (index, key) in keys.enumerated() { byRoom[rooms[index % spaces], default: []].append(key) }
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: "Workspace \(index)",
                              screens: panes ? [Self.screen(index)] : [])
        })
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: rooms.enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: keys.enumerated().map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), profile: rooms[$0 % spaces]) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"space-bench","workspace_key":"k0"}"#.utf8))
        state = WindowState(record: record)
        if state.profileID != rooms[0] { state.enterProfile(rooms[0]) }
        services.windows.registry.provisional[state.id] = keys
        controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        self.rooms = rooms
        keysByRoom = byRoom
        controller.showWorkspace(requested: state.workspaceID)
        try await Task.sleep(for: .milliseconds(300))
        drain()
        // Visit `parked` workspaces of each room (alternating rooms), then go back to the first.
        var p0 = CACurrentMediaTime(), c0 = Self.threadCPU()
        var sel = 0.0, show = 0.0, drn = 0.0
        for index in 0..<min(parked, total) {
            let a = CACurrentMediaTime()
            services.windows.select(keys[index], in: state)
            let b = CACurrentMediaTime()
            controller.showWorkspace(requested: state.workspaceID)
            let c = CACurrentMediaTime()
            drain()
            let d = CACurrentMediaTime()
            sel += b - a; show += c - b; drn += d - c
            if index % 10 == 9 {
                print(String(format: "SPACE-SWITCH-BENCH parked %d of %d wall=%.0fms cpu=%.0fms select=%.0f show=%.0f drain=%.0f mounted=%d", index + 1, total, (CACurrentMediaTime() - p0) * 1000, (Self.threadCPU() - c0) * 1000, sel * 1000, show * 1000, drn * 1000, controller.mountedContents.count))
                p0 = CACurrentMediaTime(); c0 = Self.threadCPU(); sel = 0; show = 0; drn = 0
            }
        }
        if parked > 0 {
            services.windows.select(keys[0], in: state)
            controller.showWorkspace(requested: state.workspaceID)
            try await Task.sleep(for: .milliseconds(300))
            drain()
        }
    }

    /// Workspace `index`'s one screen: a pane with a terminal tab (shown) and a browser tab.
    static func screen(_ index: Int) -> ScreenSnapshot {
        let id = UInt64(index + 1)
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [
            TabSnapshot(surface: SurfaceID(rawValue: id * 2 - 1), title: "~"),
            TabSnapshot(surface: SurfaceID(rawValue: id * 2), kind: .browser, title: "Page \(index)", url: "https://example.com/\(index)"),
        ])
        return ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(pane.id), panes: [pane])
    }

    /// Mounted workspaces of the window (shown and parked).
    var mounted: Int { controller.mountedContents.count }

    func close() {
        controller.teardown()
        controller.window?.close()
    }

    var list: SidebarListView { controller.sidebar.container.sidebarView.list }

    /// The sidebar lists `room`'s first workspace and marks `room` active.
    func shows(_ room: ProfileID) -> Bool {
        guard controller.sidebar.model.activeProfileID?.rawValue == room.rawValue, let first = keysByRoom[room]?.first else { return false }
        return list.displayed.rows.contains { $0.key == .workspace(WorkspaceID(first)) }
    }

    /// Runs pending main-queue work and run loop sources without waiting.
    func drain() {
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date()) }
    }

    /// One timed switch to `room`.
    func switchTo(_ room: ProfileID) async throws -> Sample {
        _ = SidebarView.perfCounters(reset: true)
        _ = DebugLayoutCounters.handle(["reset": .bool(true)])
        let cpu0 = Self.threadCPU(), wall0 = CACurrentMediaTime()
        services.windows.switchProfile(room, in: state)
        let sync = CACurrentMediaTime()
        var spins = 0
        while !shows(room) {
            drain()
            await Task.yield()
            spins += 1
            if spins > 20_000 { throw BenchError.neverShown(room.rawValue) }
        }
        let shown = CACurrentMediaTime()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        CATransaction.flush()
        let drawn = CACurrentMediaTime(), cpu1 = Self.threadCPU()
        var counters = SidebarView.perfCounters(reset: true).filter { !$0.key.contains("@") }
        if case let .object(layout) = DebugLayoutCounters.handle([:]) {
            for (key, value) in layout { if case let .number(n) = value { counters[key] = Int(n) } }
        }
        counters["spins"] = spins
        return Sample(cpuMs: (cpu1 - cpu0) * 1_000, wallMs: (drawn - wall0) * 1_000, syncMs: (sync - wall0) * 1_000,
                      drawMs: (drawn - shown) * 1_000, counters: counters)
    }

    /// `rounds` switches back and forth between the first two rooms (after one warm-up each way).
    func run(rounds: Int) async throws -> [Sample] {
        _ = try await switchTo(rooms[1])
        _ = try await switchTo(rooms[0])
        var samples: [Sample] = []
        for round in 0..<rounds { samples.append(try await switchTo(rooms[(round + 1) % 2])) }
        return samples
    }

    enum BenchError: Error { case neverShown(String) }

    /// Samples this process with `/usr/bin/sample` while `rounds` switches run and prints the
    /// heaviest frames of the main thread (the "top of stack" table and the call tree lines with
    /// at least `minimum` samples), for finding where a switch spends its time. The wait for
    /// `sample` is bounded and off the main thread (`SelfSampler`).
    func profile(rounds: Int, seconds: Int = 6, minimum: Int = 40) async throws {
        let (report, round) = try await SelfSampler.run(name: "space-switch", seconds: seconds) { sampler in
            try await Task.sleep(for: .milliseconds(500)) // sample attaches before the first timed switch
            var round = 0
            while sampler.isRunning, round < rounds {
                _ = try await switchTo(rooms[(round + 1) % 2])
                round += 1
            }
            return round
        }
        guard let text = report else { return print("SPACE-SWITCH-PROFILE no sample output") }
        print("SPACE-SWITCH-PROFILE rounds=\(round)")
        let lines = text.components(separatedBy: "\n")
        // The main thread's tree comes first; keep its heavy lines, trimmed.
        var inMain = false, printed = 0
        for line in lines {
            if line.contains("Thread_") { inMain = line.contains("main-thread") || line.contains("DispatchQueue_1:") }
            guard inMain, printed < 400 else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }
            guard let count = Int(trimmed.prefix { $0.isNumber }), count >= minimum else { continue }
            print("SSP " + String(line.prefix(260)))
            printed += 1
        }
        if let top = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            for line in lines[top..<min(lines.count, top + 45)] { print("SSP-TOP " + line) }
        }
    }

    /// The calling thread's CPU time, seconds.
    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// One line per field: p50 / p99 / max.
    static func summary(_ total: Int, _ samples: [Sample]) -> String {
        func row(_ name: String, _ values: [Double]) -> String {
            String(format: "%@ p50 %.2f p99 %.2f max %.2f", name, percentile(values, 0.5), percentile(values, 0.99), values.max() ?? 0)
        }
        var counterMeans: [String: Double] = [:]
        for sample in samples { for (key, value) in sample.counters { counterMeans[key, default: 0] += Double(value) / Double(samples.count) } }
        let counters = counterMeans.sorted { $0.key < $1.key }.filter { $0.value != 0 }.map { String(format: "%@=%.1f", $0.key, $0.value) }.joined(separator: " ")
        return "SPACE-SWITCH-BENCH n=\(total) | " + [row("cpu_ms", samples.map(\.cpuMs)), row("wall_ms", samples.map(\.wallMs)),
                                                     row("sync_ms", samples.map(\.syncMs)), row("draw_ms", samples.map(\.drawMs))].joined(separator: " | ")
            + " | " + counters
    }
}
