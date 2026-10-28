import AppKit
import CmuxNextCompatAppKit
import Dispatch
import Testing

/// The background open and reveal helpers run each call on the named concurrent queue
/// `com.cmuxterm.next.workspace-open`, not a root queue and not one serial queue: an open stalled in
/// LaunchServices holds no later open or reveal. The workspace is a stand-in that opens nothing.
struct NSWorkspaceBackgroundTests {
    static let wait: DispatchTimeInterval = .seconds(5)

    @Test func aStalledOpenHoldsNoLaterOpen() {
        let workspace = StallingWorkspace()
        defer { workspace.release.signal() }
        workspace.openInBackground(StallingWorkspace.stalled)
        workspace.openInBackground(URL(fileURLWithPath: "/tmp/later.txt"))
        #expect(workspace.done.wait(timeout: .now() + Self.wait) == .success, "the later open ran while the first stalled")
        #expect(workspace.labels.withLock { $0 } == ["com.cmuxterm.next.workspace-open"])
    }

    @Test func aStalledOpenHoldsNoReveal() {
        let workspace = StallingWorkspace()
        defer { workspace.release.signal() }
        workspace.openInBackground(StallingWorkspace.stalled)
        workspace.revealInBackground([URL(fileURLWithPath: "/tmp/later.txt")])
        #expect(workspace.done.wait(timeout: .now() + Self.wait) == .success, "the reveal ran while the open stalled")
        #expect(workspace.labels.withLock { $0 } == ["com.cmuxterm.next.workspace-open"])
    }
}

/// Opens and reveals nothing: an open of ``stalled`` waits for ``release``; any other call records the queue it
/// ran on and signals ``done``.
// crash-allow: its state is two semaphores and a Mutex; it reads or writes no NSWorkspace state
nonisolated private final class StallingWorkspace: NSWorkspace, @unchecked Sendable {
    static let stalled = URL(fileURLWithPath: "/Volumes/asleep/a.txt")
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let labels = Mutex<[String]>([])

    override func open(_ url: URL) -> Bool {
        if url == Self.stalled {
            release.wait()
            return false
        }
        record()
        return true
    }

    override func activateFileViewerSelecting(_ fileURLs: [URL]) {
        record()
    }

    private func record() {
        labels.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))) }
        done.signal()
    }
}
