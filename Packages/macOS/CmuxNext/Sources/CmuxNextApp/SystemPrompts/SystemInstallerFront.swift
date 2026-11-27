import AppKit
import CmuxNextCompat

/// macOS's own install dialogs that a command typed in a cmux terminal starts, brought in front of cmux.
///
/// First-run findings row 17 (clean macOS 26 VM, no Xcode tools): `git` in a cmux terminal made macOS start "Install
/// Command Line Developer Tools", whose dialog opened behind the cmux window. The person saw only the terminal's
/// "xcode-select: note: No developer tools were found" line and no dialog. macOS's cooperative activation keeps the
/// active app in front of an app that a background process launched, so cmux yields to the installer when it
/// launches while cmux is active, and the installer comes forward as if the person had opened it.
@MainActor
final class SystemInstallerFront {
    /// macOS's Command Line Tools installer (`/System/Library/CoreServices/Install Command Line Developer Tools.app`),
    /// the one a missing `git`, `make`, `clang` or `python3` starts.
    nonisolated static let installerBundleIDs: Set<String> = ["com.apple.dt.CommandLineTools.installondemand"]

    private let bundleIDs: Set<String>
    private let bundleID: @MainActor (NSRunningApplication) -> String?
    private let isActive: @MainActor () -> Bool
    private let bringForward: @MainActor (NSRunningApplication) -> Void
    /// The launch observer; it lives as long as cmux does (one per app, `AppDelegate`).
    private var observer: MainActorObservation?

    /// - Parameters:
    ///   - center: where app launches are posted (NSWorkspace's center in the app).
    ///   - bundleIDs: the installers to bring forward.
    ///   - bundleID: reads a launched app's bundle id (its own by default).
    ///   - isActive: whether cmux is the active app; an installer that launched while the person works in another
    ///     app stays where macOS put it.
    ///   - bringForward: yields cmux's activation to the installer and activates it.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, bundleIDs: Set<String> = installerBundleIDs,
         bundleID: @escaping @MainActor (NSRunningApplication) -> String? = { $0.bundleIdentifier },
         isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         bringForward: @escaping @MainActor (NSRunningApplication) -> Void = SystemInstallerFront.yield(to:)) {
        self.bundleIDs = bundleIDs
        self.bundleID = bundleID
        self.isActive = isActive
        self.bringForward = bringForward
        observer = MainActorObservation(NSWorkspace.didLaunchApplicationNotification, center: center,
                                        read: { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }) { [weak self] app in
            if let app { self?.launched(app) }
        }
    }

    private func launched(_ app: NSRunningApplication) {
        guard let id = bundleID(app), bundleIDs.contains(id), isActive() else { return }
        bringForward(app)
    }

    /// Hands activation to `app` and asks it to come forward, as a click on its Dock icon would.
    static func yield(to app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }
}
