import AppKit
import CmuxNextDesign

/// Follows the strip's window becoming and leaving main: only the main
/// window's selected tab is filled (dogfood 2026-10-08, 08). Main, not key,
/// so a dialog or palette panel taking the keyboard leaves the strip as it is.
///
/// The window's ``WindowNotices`` observes the main notices once for every strip in the window
/// and calls this follower; a released follower drops out of it.
@MainActor
final class WindowMainObserver: WindowNoticesFollower {
    private(set) var isMain = true
    private var onChange: (Bool) -> Void = { _ in }
    /// The notices of the window it follows now (the window owns them).
    private weak var notices: WindowNotices?
    /// The center the window's main changes arrive on (AppKit posts them on `NotificationCenter.default`).
    private let center: NotificationCenter

    /// Creates an observer that follows windows on `center`.
    ///
    /// - Parameter center: The center to observe (default `NotificationCenter.default`, where AppKit
    ///   posts the window's main changes; tests pass their own).
    init(center: NotificationCenter = .default) {
        self.center = center
    }

    // cx-t7hu: no isolated-deinit hop on release (the contract: OwnedTask).
    nonisolated deinit {}

    /// Starts following `window` (nil stops) and reports its current status.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let next = window.map { WindowNotices.of($0, center: center) }
        if next !== notices {
            notices?.remove(self)
            next?.add(self, for: [.becameMain, .resignedMain])
            notices = next
        }
        guard let window else { return }
        changed(isMain: window.isMainWindow)
    }

    func windowNoticed(_ notice: WindowNotice) {
        changed(isMain: notice == .becameMain)
    }

    /// Records and reports the window's main status (the window's notices call it; tests call it to
    /// drive a strip).
    func changed(isMain: Bool) {
        self.isMain = isMain
        onChange(isMain)
    }
}
