import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextWakeups
import Testing

/// Audit B7: a window none of whose workspaces a machine reports (a new window whose create waits for the daemon,
/// a restored window whose Cloud machine is offline) waits off screen at most a short limit, then shows its wait
/// state, never off screen with no limit. The wait is a measured stage of `debug.windows`.
@MainActor @Suite(.serialized)
struct WindowContentWaitTests {
    @Test func aWindowWhoseWorkspaceNoMachineReportsShowsAfterItsLimit() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let windows = fixture.services.windows
        let controller = try #require(windows.openWindow(workspaces: ["b7-never-reported"]))
        let id = controller.state.id
        #expect(windows.awaitingContent[id] != nil, "it waits off screen first: never an empty frame at once")
        #expect(fixture.presented.isEmpty)

        try await fixture.passLimit { fixture.presented.contains(id) }
        #expect(fixture.presented == [id], "a window whose workspace no machine reports stays off screen past its limit")
        #expect(windows.awaitingContent[id] == nil, "it still waits off screen after its limit")
        #expect(controller.recoveryShows == "connecting", "it shows nothing in its content area")
        #expect(WindowInvariants.problems(windows).isEmpty, "a window shown at its limit breaks a window invariant")
        let stage = try #require(Self.waitStage(WindowInvariants.report(windows), window: id), "debug.windows has no off-screen wait stage")
        #expect(stage["ended"] == .string("limit"), "the stage does not say its limit ended the wait")
        #expect(stage["reason"] == .string("new_window"))
    }

    @Test func aRestoredWindowOfAnOfflineCloudMachineShowsReconnecting() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let windows = fixture.services.windows
        let machine = "b7-cloud-machine", workspace = WorkspaceKey(rawValue: "b7-cloud-workspace")
        let record = WindowRecord(id: "b7-restored", workspaceKey: workspace, workspaceKeys: [workspace], machine: machine)
        windows.states[record.id] = WindowState(record: record)
        windows.registry.apply { registry in
            registry = WindowRegistry(records: [record])
            return WindowRegistry.Changes()
        }
        windows.sync(previous: [:])
        let controller = try #require(windows.controller(for: record.id))
        #expect(windows.awaitingContent[record.id] != nil, "it waits off screen first for its machine")

        try await fixture.passLimit { fixture.presented.contains(record.id) }
        #expect(fixture.presented == [record.id], "a restored window whose Cloud machine is offline stays off screen with no limit")
        let reconnecting = RemoteStrings.placeholderReconnecting(machine)
        #expect(Self.shownTexts(in: controller.window?.contentView).contains(reconnecting),
                "the window shows no \"\(reconnecting)\" state")
        #expect(WindowInvariants.problems(windows).isEmpty, "a window shown at its limit breaks a window invariant")
    }

    /// The off-screen wait's stage of window `id` in a `debug.windows` report.
    private static func waitStage(_ report: CmuxNextSettings.JSONValue, window id: String) -> CmuxNextSettings.JSONValue? {
        guard case .array(let windows)? = report["windows"] else { return nil }
        return windows.first { $0["id"] == .string(id) }?["offscreen_wait"]
    }

    /// The text of every label drawn in `view`: not hidden and not transparent, nor any view above it.
    private static func shownTexts(in view: NSView?) -> [String] {
        guard let view, !view.isHidden, view.alphaValue > 0 else { return [] }
        let own = (view as? NSTextField)?.stringValue ?? (view as? ChromeLabel)?.stringValue
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { shownTexts(in: $0) }
    }

    /// Services on a scheduler the test runs (its frames run posted work), with windows never ordered in.
    @MainActor private final class Fixture {
        let rig = MainDeadlineRig()
        let services: AppServices
        private(set) var presented: [String] = []

        init() {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.work)
            services.windows.ordersWindowsIn = false
            services.windows.onPresent = { [weak self] controller in self?.presented.append(controller.state.id) }
        }

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
        }

        /// Lets real time pass (up to 3 s, past every wait's limit) until `done`: each step fires the scheduler's
        /// wake-up queue (its deadlines are on the real uptime) and runs the work they posted in one frame.
        func passLimit(until done: () -> Bool) async throws {
            var steps = 0
            while !done(), steps < 60 {
                try await Task.sleep(for: .milliseconds(50))
                rig.work.wakeUps.fire()
                rig.frame()
                steps += 1
            }
        }
    }
}
