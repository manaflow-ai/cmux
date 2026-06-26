import CmuxSidebar
import Foundation
import Observation

/// Owns the sidebar tab-item settings projection consumed by `VerticalTabsSidebar`.
///
/// Single-writer: every mutation of ``snapshot`` happens on the main actor through
/// ``refreshSnapshot()``, fed by two live inputs. `UserDefaults.didChangeNotification`
/// re-reads the defaults-backed fields, and `.ghosttyConfigDidReload` re-loads the
/// Ghostty sidebar font size off-main via ``sidebarFontSizeProvider`` and folds the
/// clamped result back into the snapshot. The snapshot is only replaced when it
/// actually changes, so SwiftUI re-renders track real settings transitions rather
/// than notification churn.
@MainActor
@Observable
final class SidebarTabItemSettingsStore {
    private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private let sidebarFontSizeProvider: () async -> CGFloat
    private var sidebarFontSize: CGFloat
    private nonisolated(unsafe) var sidebarFontSizeLoadTask: Task<Void, Never>?
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    private nonisolated(unsafe) var ghosttyConfigObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        initialSidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize,
        sidebarFontSizeProvider: @escaping () async -> CGFloat = SidebarFontSizeProvider.loadFromGhosttyConfig
    ) {
        let clampedSidebarFontSize = GhosttyConfig.clampedSidebarFontSize(initialSidebarFontSize)
        self.defaults = defaults
        self.sidebarFontSize = clampedSidebarFontSize
        self.sidebarFontSizeProvider = sidebarFontSizeProvider
        self.snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: clampedSidebarFontSize
        )
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        refreshSidebarFontSize()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
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
        let nextSnapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func refreshSidebarFontSize() {
        sidebarFontSizeLoadTask?.cancel()
        sidebarFontSizeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loadedSidebarFontSize = await sidebarFontSizeProvider()
            guard !Task.isCancelled else { return }
            sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(loadedSidebarFontSize)
            refreshSnapshot()
        }
    }
}
