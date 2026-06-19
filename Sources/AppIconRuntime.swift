import AppKit
import CmuxSettings
import Foundation

// The App-Icon picker labels live in `CmuxSettingsUI`'s `AppIconPickerRow`
// (its own `iconDisplayName`), so no app-side `AppIconMode.displayName` is
// needed; the legacy app-target enum's `displayName` was unreferenced and is
// intentionally not carried over.

// MARK: - KVO/launch observation tokens (the sanctioned KVO seam)

/// Wraps a closure-based `NotificationCenter` launch observer as an
/// ``AppIconAppearanceObservation`` token so the AppKit-free settings package
/// can hold and cancel it without naming `NSObjectProtocol`.
private final class AppIconLaunchObserverToken: AppIconAppearanceObservation {
    private var token: NSObjectProtocol?
    private let center: NotificationCenter

    init(token: NSObjectProtocol, center: NotificationCenter) {
        self.token = token
        self.center = center
    }

    func invalidate() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }
}

/// `NSKeyValueObservation` is the live `effectiveAppearance` token. Conforming it
/// to ``AppIconAppearanceObservation`` is the one sanctioned KVO seam for the
/// app-icon subsystem (`UserDefaults`/`NSApplication` expose appearance change
/// only via KVO); the conformance lives app-side because the settings package
/// must not import AppKit.
extension NSKeyValueObservation: AppIconAppearanceObservation {}

// MARK: - Composition-root anchors

/// Tracks whether `applicationDidFinishLaunching` has run. Exactly one reporter
/// is constructed at process start so the launch path and the icon appliers
/// share one flag (Tahoe defers icon work until launch — see the type docs).
let appIconLaunchReporter = AppIconLaunchPhaseReporter()

/// The single appearance observer shared by every icon-apply path, so
/// `automatic` mode installs exactly one `effectiveAppearance` KVO. Constructed
/// at process start with the live AppKit environment; replaces the former
/// `AppIconAppearanceObserver.shared` singleton.
@MainActor
let appIconAppearanceObserver = AppIconAppearanceObserver(
    environment: AppIconAppearanceObserver.Environment(
        isApplicationFinishedLaunching: {
            appIconLaunchReporter.isApplicationFinishedLaunching()
        },
        startEffectiveAppearanceObservation: { handler in
            guard let app = NSApp else { return nil }
            return app.observe(\.effectiveAppearance, options: []) { _, _ in
                DispatchQueue.main.async {
                    handler()
                }
            }
        },
        addDidFinishLaunchingObserver: { handler in
            let token = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { _ in
                handler()
            }
            return AppIconLaunchObserverToken(token: token, center: .default)
        },
        currentAppearanceIsDark: {
            guard let app = NSApp else { return nil }
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        },
        applyIconImage: { imageName in
            guard let icon = NSImage(named: imageName) else { return false }
            NSApplication.shared.applicationIconImage = icon
            return true
        }
    )
)

/// Composition-root anchor for the app-icon apply service. Exactly one
/// ``AppIconApplier`` is constructed at process start and shared by the three
/// app-target callers (`AppDelegate` launch icon, the `HostSettingsActions`
/// App-Icon picker observer, and the managed-config reload path) so they drive
/// the single shared appearance observer above. Mirrors the `telemetrySettings`
/// anchor in `cmuxApp.swift`: one file-scope binding bound at process start,
/// lazy and thread-safe like the `static let` it replaced, never a
/// `static let shared` on a stateful type.
@MainActor
let appIconApplier = AppIconApplier(
    store: AppIconSettingsStore(defaults: .standard),
    environment: AppIconApplier.Environment(
        isApplicationFinishedLaunching: {
            appIconLaunchReporter.isApplicationFinishedLaunching()
        },
        applyManualIcon: { mode in
            guard let imageName = mode.imageName, let icon = NSImage(named: imageName) else { return }
            NSApplication.shared.applicationIconImage = icon
        },
        startAppearanceObservation: {
            appIconAppearanceObserver.startObserving()
        },
        stopAppearanceObservation: {
            appIconAppearanceObserver.stopObserving()
        },
        notifyDockTilePlugin: {
            // Suppress the cross-process dock-tile ping under XCTest so test
            // runs do not post DistributedNotificationCenter traffic (matches
            // the legacy `AppIconSettings` guard). The signals cover plain
            // XCTest plus the UI-test launch markers.
            let env = ProcessInfo.processInfo.environment
            let underXCTest = env["XCTestConfigurationFilePath"] != nil
                || env["XCTestBundlePath"] != nil
                || env["XCTestSessionIdentifier"] != nil
                || env["XCInjectBundle"] != nil
                || env["XCInjectBundleInto"] != nil
                || env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true
                || env.keys.contains { $0.hasPrefix("CMUX_UI_TEST_") }
            guard !underXCTest else { return }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.cmuxterm.appIconDidChange"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    )
)
