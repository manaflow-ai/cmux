import Foundation
import Observation

enum SidebarFontSizeProvider {
    @concurrent
    static func loadFromGhosttyConfig() async -> CGFloat {
        GhosttyConfig.load().sidebarFontSize
    }
}

@MainActor
@Observable
final class SidebarTabItemSettingsStore {
    private(set) var snapshot: SidebarTabItemSettingsSnapshot

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sidebarFontSizeProvider: @Sendable () async -> CGFloat
    @ObservationIgnored private var sidebarFontSize: CGFloat
    @ObservationIgnored private var sidebarFontSizeLoadTask: Task<Void, Never>?
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(
        defaults: UserDefaults = .standard,
        initialSidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize,
        sidebarFontSizeProvider: @escaping @Sendable () async -> CGFloat = {
            await SidebarFontSizeProvider.loadFromGhosttyConfig()
        }
    ) {
        self.defaults = defaults
        self.sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(initialSidebarFontSize)
        self.sidebarFontSizeProvider = sidebarFontSizeProvider
        self.snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        observationTasks = [
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UserDefaults.didChangeNotification
                ) {
                    guard !Task.isCancelled, let self else { return }
                    refreshSnapshot()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .ghosttyConfigDidReload
                ) {
                    guard !Task.isCancelled, let self else { return }
                    refreshSidebarFontSize()
                }
            }
        ]
        refreshSidebarFontSize()
    }

    deinit {
        sidebarFontSizeLoadTask?.cancel()
        observationTasks.forEach { $0.cancel() }
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
