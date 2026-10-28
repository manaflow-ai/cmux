import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextMetrics
import CmuxNextTestSupport
import Foundation
import QuartzCore

/// Every switch a person makes, timed in-process over the switch-at-scale fixture (SwitchScaleFixture,
/// switch_scale.py): 3 windows over N workspaces in spaces and groups, each workspace 2-6 screens of 4-12 panes of
/// 2-8 mixed tabs, and Home (switch-scale.md, Lawrence 2026-10-28). The store holds the whole tree (159,505 tabs at
/// 1,000 workspaces); no daemon runs, so no terminal produces output and no page loads: the numbers are the app's
/// own main-thread work of the switch, which must not grow with N (O(visible)).
///
/// One switch is timed from its call (the same call the key, click or palette pick makes) until the window shows the
/// new content (the kind's `shown` check), then its layout, display and Core Animation commit. `cpu` is the main
/// thread's CPU time over all of it, `wall` the wall time, `sync` the call itself, `draw` the layout and display
/// after the content showed, `turns` the run loop drains until it showed.
@MainActor
final class SwitchScaleBench {
    enum Kind: String, CaseIterable, Sendable {
        case space, screen, tab, pane, window, home
        case workspaceClick = "workspace_click"
        case workspaceDigit = "workspace_digit"
        case workspaceNext = "workspace_next"
        case workspacePalette = "workspace_palette"
    }

    struct Sample {
        var cpuMs: Double
        var wallMs: Double
        var syncMs: Double
        var drawMs: Double
        var turns: Int
        /// False when the content did not show within the turn limit (counted, never dropped).
        var shown: Bool
    }

    let fixture: SwitchScaleFixture
    let services: AppServices
    private(set) var controllers: [WindowController] = []
    /// The window the key window source names (the one the actions act on).
    private(set) var current: WindowController?
    let keysByRoom: [ProfileID: [String]]
    let roomOfKey: [String: ProfileID]

    static let turnLimit = 4_000

    init(workspaces: Int) async throws {
        fixture = try await SwitchScaleFixture.load(workspaces: workspaces)
        _ = NSApplication.shared
        services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: fixture.tree())
        var byRoom: [ProfileID: [String]] = [:], roomOf: [String: ProfileID] = [:]
        for (index, workspace) in fixture.workspaces.enumerated() {
            let key = SwitchScaleFixture.key(index), room = SwitchScaleFixture.room(workspace.space)
            byRoom[room, default: []].append(key)
            roomOf[key] = room
        }
        keysByRoom = byRoom
        roomOfKey = roomOf
        // Window 0 lists every workspace and Home but the other windows' own; each other window lists its one.
        let shown = fixture.windows.map { SwitchScaleFixture.key($0.workspace) }
        let elsewhere = Set(shown.dropFirst())
        let all = fixture.workspaces.indices.map(SwitchScaleFixture.key) + (fixture.home ? [SwitchScaleFixture.homeKey] : [])
        for (index, window) in fixture.windows.enumerated() {
            let id = "switch-scale-\(index)"
            services.windows.registry.provisional[id] = index == 0 ? all.filter { !elsewhere.contains($0) } : [shown[index]]
            let controller = services.windows.makeController(for: WindowRegistry.Window(id: id))
            let room = SwitchScaleFixture.room(window.space)
            if controller.state.profileID != room { controller.state.enterProfile(room) }
            services.windows.select(shown[index], in: controller.state)
            controller.showWorkspace(requested: controller.state.workspaceID)
            controllers.append(controller)
        }
        current = controllers.first
        services.keyWindowSource = { [weak self] in self?.current?.window }
        var waits = 0
        while controllers.contains(where: { $0.content == nil }), waits < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waits += 1
        }
        drain()
    }

    var main: WindowController { controllers[0] }

    func close() {
        for controller in controllers {
            controller.teardown()
            controller.window?.close()
        }
        controllers = []
        current = nil
    }

    /// Runs pending main-queue work and run loop sources without waiting.
    func drain() {
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date()) }
    }

    /// One timed switch: `perform` makes it, `shown` says the window shows the new content.
    func timed(_ perform: () -> Void, shown: () -> Bool) async -> Sample {
        let cpu0 = SpaceSwitchBench.threadCPU(), wall0 = CACurrentMediaTime()
        perform()
        let sync = CACurrentMediaTime()
        var turns = 0
        while !shown(), turns < Self.turnLimit {
            drain()
            await Task.yield()
            turns += 1
        }
        let didShow = shown()
        let shownAt = CACurrentMediaTime()
        for controller in controllers {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
        }
        CATransaction.flush()
        let drawn = CACurrentMediaTime(), cpu1 = SpaceSwitchBench.threadCPU()
        return Sample(cpuMs: (cpu1 - cpu0) * 1_000, wallMs: (drawn - wall0) * 1_000, syncMs: (sync - wall0) * 1_000,
                      drawMs: (drawn - shownAt) * 1_000, turns: turns, shown: didShow)
    }

    /// The main window's room and two of its workspaces, for the alternating switches.
    var pair: (String, String) {
        let keys = keysByRoom[main.state.profileID] ?? []
        return (keys.first ?? SwitchScaleFixture.key(0), keys.dropFirst().first ?? keys.first ?? SwitchScaleFixture.key(0))
    }

    var shownWorkspace: String? { main.content?.workspace.id }

    func invoke(_ id: ActionID) { _ = services.registry.perform(id, invocation: ActionInvocation(origin: .user)) }

    /// Switch `round` of `kind` (alternating directions or targets), timed.
    func step(_ kind: Kind, round: Int) async -> Sample {
        current = main
        switch kind {
        case .space:
            let room = SwitchScaleFixture.room(round % 2 == 0 ? 1 : 0)
            let keys = Set(keysByRoom[room] ?? [])
            return await timed({ services.windows.switchProfile(room, in: main.state) }, shown: {
                main.state.profileID == room && (shownWorkspace.map { keys.contains($0) } ?? false)
            })
        case .screen:
            let before = main.content?.layoutModel.activeScreenID
            return await timed({ invoke(round % 2 == 0 ? "screen.next" : "screen.previous") }, shown: {
                main.content?.layoutModel.activeScreenID != before
            })
        case .tab:
            let before = main.focusedPane?.stripModel.selectedID
            return await timed({ invoke(round % 2 == 0 ? "nextSurface" : "prevSurface") }, shown: {
                main.focusedPane?.stripModel.selectedID != before
            })
        case .pane:
            let before = main.focusedPane
            return await timed({ invoke("focusNextPane") }, shown: { main.focusedPane !== before })
        case .window:
            let next = controllers[(round + 1) % controllers.count]
            current = next
            // A test process that is not the active app cannot make a window key: then the activation call is the switch.
            return await timed({ if let window = next.window { WindowActivation.show(window, .focus) } }, shown: {
                !NSApp.isActive || next.window?.isKeyWindow == true
            })
        case .home:
            if round % 2 == 0 {
                return await timed({ _ = AppActions.showHome(services) }, shown: { main.content?.workspace.kind == "home" })
            }
            let target = pair.0
            return await timed({ services.windows.show(workspaceID: target, in: main.state, from: .thisWindow) },
                               shown: { shownWorkspace == target })
        case .workspaceClick:
            let target = round % 2 == 0 ? pair.1 : pair.0
            return await timed({ services.windows.show(workspaceID: target, in: main.state, from: .thisWindow) },
                               shown: { shownWorkspace == target })
        case .workspaceDigit:
            let before = shownWorkspace
            return await timed({ SidebarNavigation.select(number: round % 2 == 0 ? 2 : 1, services) }, shown: { shownWorkspace != before })
        case .workspaceNext:
            let before = shownWorkspace
            return await timed({ SidebarNavigation.step(by: round % 2 == 0 ? 1 : -1, services) }, shown: { shownWorkspace != before })
        case .workspacePalette:
            let target = round % 2 == 0 ? pair.1 : pair.0
            return await timed({
                let source = PaletteSourcesBridge.WorkspaceSource(services: services)
                _ = source.workspaces  // what opening the palette's workspace list reads
                source.selectWorkspace(id: target)
            }, shown: { shownWorkspace == target })
        }
    }

    /// `rounds` timed switches of `kind` after two untimed ones, from the main window on its first workspace.
    func run(_ kind: Kind, rounds: Int) async -> [Sample] {
        settle()
        for round in 0..<2 { _ = await step(kind, round: round) }
        var samples: [Sample] = []
        for round in 0..<rounds { samples.append(await step(kind, round: round)) }
        settle()
        return samples
    }

    /// Back to the main window, room 0, its first workspace.
    func settle() {
        current = main
        if main.state.profileID != SwitchScaleFixture.room(0) { services.windows.switchProfile(SwitchScaleFixture.room(0), in: main.state) }
        drain()
        if let first = keysByRoom[SwitchScaleFixture.room(0)]?.first, shownWorkspace != first {
            services.windows.show(workspaceID: first, in: main.state, from: .thisWindow)
        }
        drain()
    }

    /// The app's physical footprint (one system call, off the main thread).
    static func footprint() async -> UInt64 {
        let pid = getpid()
        return await Task.detached { MemorySampler.physicalFootprint(of: pid) ?? 0 }.value
    }

    // MARK: Report

    static func percentile(_ values: [Double], _ p: Double) -> Double { SpaceSwitchBench.percentile(values, p) }

    static func line(_ size: Int, _ kind: Kind, _ samples: [Sample], mounted: Int) -> String {
        func row(_ name: String, _ values: [Double]) -> String {
            String(format: "%@ p50 %.2f p99 %.2f max %.2f", name, percentile(values, 0.5), percentile(values, 0.99), values.max() ?? 0)
        }
        let missed = samples.filter { !$0.shown }.count
        let turns = samples.map { Double($0.turns) }
        return "SWITCH-SCALE n=\(size) kind=\(kind.rawValue) switches=\(samples.count) not_shown=\(missed) mounted=\(mounted) | "
            + [row("cpu_ms", samples.map(\.cpuMs)), row("wall_ms", samples.map(\.wallMs)), row("sync_ms", samples.map(\.syncMs)),
               row("draw_ms", samples.map(\.drawMs)), row("turns", turns)].joined(separator: " | ")
    }

    /// result-v1 when CMUX_PERF_RESULT_DIR is set (lab story swift-switch-scale).
    static func record(_ size: Int, _ kind: Kind, _ samples: [Sample]) throws {
        guard let results = try PerfResultWriter(), !samples.isEmpty else { return }
        let name = "swift.switch_scale.\(kind.rawValue).\(size)"
        try results.record("\(name).cpu", unit: .ms, samples: samples.map(\.cpuMs))
        try results.record("\(name).wall", unit: .ms, samples: samples.map(\.wallMs))
        try results.record("\(name).draw", unit: .ms, samples: samples.map(\.drawMs))
    }

    /// Samples this process with `/usr/bin/sample` while `rounds` switches of `kind` run and prints the main thread's
    /// heaviest call tree lines and top of stack (where a switch spends its time).
    func profile(_ kind: Kind, rounds: Int, seconds: Int = 8) async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("switch-scale-\(getpid())-\(kind.rawValue).txt")
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(getpid()), String(seconds), "1", "-mayDie", "-file", output.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        let ended = AsyncStream<Void> { continuation in sampler.terminationHandler = { _ in continuation.yield(); continuation.finish() } }
        try sampler.run()
        try await Task.sleep(for: .milliseconds(500))  // sample attaches before the first timed switch
        var round = 0
        while sampler.isRunning, round < rounds {
            _ = await step(kind, round: round)
            round += 1
        }
        for await _ in ended { break }
        guard let text = try? String(contentsOf: output, encoding: .utf8) else { return print("SWITCH-SCALE-PROFILE \(kind.rawValue) no sample output") }
        print("SWITCH-SCALE-PROFILE \(kind.rawValue) rounds=\(round)")
        let lines = text.components(separatedBy: "\n")
        var inMain = false, printed = 0
        for line in lines {
            if line.contains("Thread_") { inMain = line.contains("main-thread") || line.contains("DispatchQueue_1:") }
            guard inMain, printed < 300 else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }
            guard let count = Int(trimmed.prefix { $0.isNumber }), count >= 30 else { continue }
            print("SSP \(kind.rawValue) " + String(line.prefix(240)))
            printed += 1
        }
        if let top = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            for line in lines[top..<min(lines.count, top + 40)] { print("SSP-TOP \(kind.rawValue) " + line) }
        }
    }
}
