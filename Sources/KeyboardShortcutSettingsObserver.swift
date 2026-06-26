import Combine
import Foundation
import Observation

@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var settingsCancellable: AnyCancellable?
    @ObservationIgnored private var recorderCancellable: AnyCancellable?

    /// Composition-root-owned single instance, recorded once at startup.
    /// `nonisolated(unsafe)`: written exactly once in
    /// ``AppDelegate/configure`` (with the cmuxApp-owned `@StateObject`)
    /// before any concurrent reader exists. Retires together with the
    /// transitional ``shared`` accessor once every view site is injected.
    nonisolated(unsafe) private static var compositionRootInstance: KeyboardShortcutSettingsObserver?

    /// The single instance, lazily constructed on first access. The cmuxApp
    /// `@StateObject` resolves this through ``shared`` and `AppDelegate`
    /// installs the same object as the composition-root instance, so there is
    /// exactly one observer (revision counter) across every consumer.
    private static let instance = KeyboardShortcutSettingsObserver()

    /// Transitional accessor for the de-singletonization (CONVENTIONS §5
    /// `static let shared` → construct-and-inject). The type no longer
    /// self-vivifies an eager `static let shared`; the cmuxApp `@StateObject`
    /// owns the single instance and injects it into `AppDelegate` (which records
    /// ownership via ``installCompositionRootInstance(_:)``). The SwiftUI view
    /// sites (`ContentView`, `WorkspaceContentView`, `RightSidebarPanelView`,
    /// `NotificationsPage`, `BrowserPanelView`, `UpdateTitlebarAccessory`) still
    /// reach the same single object here while they are migrated to an injected
    /// reference; dropping ``shared`` is the end state.
    static var shared: KeyboardShortcutSettingsObserver {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` (in `configure`, with the cmuxApp-owned
    /// `@StateObject`) to record composition-root ownership of the single
    /// instance. Idempotent (keeps the first installed instance).
    static func installCompositionRootInstance(_ instance: KeyboardShortcutSettingsObserver) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

    init(notificationCenter: NotificationCenter = .default) {
        settingsCancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision &+= 1 }
        recorderCancellable = notificationCenter.publisher(for: KeyboardShortcutRecorderActivity.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision &+= 1 }
    }
}
