@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization

/// A frame source the test fires by hand (or never, to model a stalled
/// main thread).
final class ManualFrameSource: ControlFrameSource {
    private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0.append(work) }
    }

    var scheduledCount: Int { pending.withLock { $0.count } }

    /// Runs every scheduled frame callback once.
    @MainActor
    func fire() {
        let works = pending.withLock { works in
            defer { works.removeAll() }
            return works
        }
        for work in works { work() }
    }
}

/// Busy-waits on the current thread (tests model a stalled main thread).
func spin(for duration: Duration) {
    let end = ContinuousClock.now + duration
    while ContinuousClock.now < end {}
}

/// Executor that counts calls and can spin inside the handler.
final class CountingExecutor: ControlActionExecutor {
    let calls = Atomic<Int>(0)
    let work: Duration

    init(work: Duration = .zero) {
        self.work = work
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        calls.add(1, ordering: .relaxed)
        if work > .zero { spin(for: work) }
        return .ran
    }
}

extension ControlSnapshot {
    static func sample() -> ControlSnapshot {
        var snapshot = ControlSnapshot()
        snapshot.catalog = sampleCatalog()
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        let tab = ControlTabInfo(id: "tab-1", surface: "11", kind: "terminal", title: "zsh", columns: 80, rows: 24, cwd: "/tmp")
        let pane = ControlPaneInfo(id: "pane-1", handle: "5", selectedTabID: "tab-1", tabs: [tab])
        topology.workspaces = [ControlWorkspaceInfo(id: "ws-1", handle: "1", name: "Main",
                                                    screens: [ControlScreenInfo(id: "screen-1", handle: "2", panes: [pane])])]
        topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: "ws-1", isKey: true, isVisible: true, focusedPaneID: "pane-1")]
        topology.focus = ControlFocus(windowID: "win-1", workspaceID: "ws-1", paneID: "pane-1", tabID: "tab-1")
        snapshot.topology = topology
        snapshot.settings = ["appearance": ["density": "compact"]]
        return snapshot
    }
}
