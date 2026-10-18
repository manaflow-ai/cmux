public import AppKit
public import CmuxNextDesign
import QuartzCore

/// `debug.new_workspace`: per new workspace, the press (`pressed`) to the frame its sidebar row is
/// first drawn (`drew`), as `SwitchFrameTimer` times a tab switch (`apply_ms`, `commit_ms`,
/// `late_vsyncs`), and `walks`: the rows passes that walked every workspace (`SidebarSameTurn`)
/// between the two. A new workspace's row is drawn from the press, before the daemon creates it
/// (the App's PendingWorkspaceRows), so it needs no walk: perf-gate.py's new_workspaces scenario gates
/// `walks` 0 for every create.
@MainActor
public final class SidebarNewRowTimer {
    public static let shared = SidebarNewRowTimer()

    /// Its socket method reads and starts or stops this (the App's `debug.new_workspace`).
    public let timer = SwitchFrameTimer(owner: "debug.new_workspace")
    /// The presses whose create has not named its workspace yet, oldest first (creates run in press order).
    private var presses: [CFTimeInterval] = []
    /// The rebuild count at each create's press, by workspace id.
    private var walksAtPress: [String: Int] = [:]

    init() {
        timer.onStart = { [weak self] in
            self?.presses = []
            self?.walksAtPress = [:]
        }
    }

    /// A person or script asked for a new workspace (the App's `newTab` action), now.
    public func pressed() {
        guard timer.isRecording else { return }
        presses.append(CACurrentMediaTime())
    }

    /// The create of the oldest press (else one with no press, from now) is workspace `id`.
    public func began(_ id: String) {
        guard timer.isRecording else { return }
        walksAtPress[id] = Self.walks
        timer.began(id, at: presses.isEmpty ? CACurrentMediaTime() : presses.removeFirst())
    }

    /// The list of `window` drew `sections`: a waiting workspace listed there is shown.
    func drew(_ sections: [SidebarSection], in window: NSWindow?) {
        guard timer.isRecording, !walksAtPress.isEmpty else { return }
        for section in sections {
            for workspace in section.workspaces {
                let id = workspace.id.rawValue
                guard let walks = walksAtPress[id], timer.isWaiting(id) else { continue }
                walksAtPress[id] = nil
                timer.shown(id, in: window, extra: ["walks": Double(Self.walks - walks)])
            }
        }
    }

    private static var walks: Int { SidebarPerfCounters.count(.rebuilds) }
}
