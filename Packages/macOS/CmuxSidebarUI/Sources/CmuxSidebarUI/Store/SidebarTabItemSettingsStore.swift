public import CoreGraphics
public import Foundation
import Observation

/// Observes the two notification streams that can change the sidebar-row
/// settings (a `UserDefaults` change and a Ghostty-config reload) and
/// republishes a freshly built ``Snapshot`` whenever the inputs change.
///
/// The store is generic over the snapshot value type so it stays free of the
/// app target's settings catalog, `UserDefaults`, and Ghostty config. The app
/// composition root injects:
///
/// - a ``snapshotBuilder`` closure that reads its own settings (the catalog,
///   defaults, and the resolved sidebar font size) and produces a `Snapshot`;
/// - a ``fontSizeProvider`` async closure that loads the live Ghostty sidebar
///   font size off the main actor;
/// - a ``clampFontSize`` closure that applies the app's font-size bounds;
/// - the two ``Notification.Name`` values to observe (a `UserDefaults` change
///   name and the app-defined Ghostty-config-reload name).
///
/// Republish is gated on `Snapshot` equality, so an orthogonal `UserDefaults`
/// write that does not change any observed key does not invalidate the SwiftUI
/// readers. This is the byte-faithful lift of the app's former
/// `SidebarTabItemSettingsStore`: same observe/debounce ordering, same
/// equality gate, same font-size load/cancel behavior.
@MainActor
@Observable
public final class SidebarTabItemSettingsStore<Snapshot: Equatable & Sendable> {
    /// The most recently published settings snapshot. Single-writer on the
    /// main actor; SwiftUI readers observe this.
    public private(set) var snapshot: Snapshot

    private let snapshotBuilder: @MainActor (CGFloat) -> Snapshot
    private let fontSizeProvider: () async -> CGFloat
    private let clampFontSize: @Sendable (CGFloat) -> CGFloat
    private var sidebarFontSize: CGFloat
    private var sidebarFontSizeLoadTask: Task<Void, Never>?
    private var defaultsObserver: (any NSObjectProtocol)?
    private var ghosttyConfigObserver: (any NSObjectProtocol)?

    /// Creates the store, seeds the initial snapshot synchronously, and arms
    /// both notification observers plus the first font-size load.
    ///
    /// - Parameters:
    ///   - initialSidebarFontSize: the font size to seed the first snapshot
    ///     with, before ``fontSizeProvider`` resolves the live value.
    ///   - clampFontSize: applies the app's font-size bounds; called on the
    ///     seed value and on every loaded value.
    ///   - snapshotBuilder: builds a `Snapshot` for the supplied font size,
    ///     reading the app's settings. Runs on the main actor.
    ///   - fontSizeProvider: loads the live sidebar font size off the main
    ///     actor; awaited on init and on every Ghostty-config reload.
    ///   - defaultsChangedNotification: the notification name whose posts mean
    ///     a settings default may have changed (`UserDefaults.didChangeNotification`).
    ///   - ghosttyConfigDidReloadNotification: the app-defined notification name
    ///     whose posts mean the Ghostty config (and thus the sidebar font size)
    ///     reloaded.
    public init(
        initialSidebarFontSize: CGFloat,
        clampFontSize: @escaping @Sendable (CGFloat) -> CGFloat,
        snapshotBuilder: @escaping @MainActor (CGFloat) -> Snapshot,
        fontSizeProvider: @escaping () async -> CGFloat,
        defaultsChangedNotification: Notification.Name,
        ghosttyConfigDidReloadNotification: Notification.Name
    ) {
        self.clampFontSize = clampFontSize
        self.sidebarFontSize = clampFontSize(initialSidebarFontSize)
        self.snapshotBuilder = snapshotBuilder
        self.fontSizeProvider = fontSizeProvider
        self.snapshot = snapshotBuilder(sidebarFontSize)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: defaultsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        refreshSidebarFontSize()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: ghosttyConfigDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSidebarFontSize()
            }
        }
    }

    deinit {
        sidebarFontSizeLoadTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(ghosttyConfigObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = snapshotBuilder(sidebarFontSize)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func refreshSidebarFontSize() {
        sidebarFontSizeLoadTask?.cancel()
        sidebarFontSizeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loadedSidebarFontSize = await fontSizeProvider()
            guard !Task.isCancelled else { return }
            sidebarFontSize = clampFontSize(loadedSidebarFontSize)
            refreshSnapshot()
        }
    }
}
