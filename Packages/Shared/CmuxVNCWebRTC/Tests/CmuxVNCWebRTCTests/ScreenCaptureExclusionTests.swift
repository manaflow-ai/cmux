@testable import CmuxVNCWebRTC
import CoreGraphics
import Testing

/// SECURITY (cmux#37286): screen sharing leaves out each window the app names (a prompt only the
/// person may see, such as the join consent ask) and every window of a process it names, and keeps
/// every other window in the stream.
struct ScreenCaptureExclusionTests {
    @Test func theNamedWindowsAndTheNamedProcessesWindowsStayOut() {
        let windows: [(id: CGWindowID, pid: pid_t?)] = [(1, 100), (2, 100), (3, 200), (4, nil), (5, 300)]
        let exclusion = ScreenCaptureBackend.Exclusion(pids: [200], windows: [2, 4])
        #expect(ScreenCaptureBackend.excludedWindows(windows, excluding: exclusion) == [2, 3, 4])
        #expect(ScreenCaptureBackend.excludedWindows(windows, excluding: .init()).isEmpty)
    }
}
