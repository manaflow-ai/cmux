@testable import CmuxNextCompat
import CoreGraphics
import Testing

/// SECURITY (cmux#37286): every capture cmux makes leaves out each of the app's windows with
/// `sharingType = .none` by id (macOS 15.4+ may capture such a window), and only those.
struct CaptureExcludedWindowsTests {
    @Test func onlyThisAppsWindowsThatAskNotToBeSharedAreLeftOut() {
        func window(_ number: Int, pid: Int, sharing: CGWindowSharingType) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid,
             kCGWindowSharingState as String: Int(sharing.rawValue)]
        }
        let windows = [
            window(1, pid: 100, sharing: .none),
            window(2, pid: 100, sharing: .readOnly),
            window(3, pid: 200, sharing: .none), // another app's: not ours to leave out
            window(4, pid: 100, sharing: .none),
            [kCGWindowNumber as String: 5, kCGWindowOwnerPID as String: 100], // no sharing state: shared
        ]
        #expect(CaptureExcludedWindows.excluded(windows, of: 100) == [1, 4])
        #expect(CaptureExcludedWindows.excluded(windows, of: 300).isEmpty)
    }
}
