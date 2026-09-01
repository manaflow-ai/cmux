import AppKit
import Foundation

/// Owns asynchronous custom-icon resolution for the application lifecycle.
@MainActor
final class AppIconSettingsApplication {
    private var applyTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Cancels any older resolution and applies the currently selected icon.
    ///
    /// The resolver runs asynchronously, while all AppKit mutations remain on
    /// the main actor. A generation token prevents an older task's cleanup from
    /// clearing a newer task that replaced it.
    func applyCurrentIcon(
        defaults: UserDefaults,
        environment: AppIconSettings.Environment
    ) {
        generation &+= 1
        let requestGeneration = generation
        applyTask?.cancel()
        applyTask = nil

        guard environment.isApplicationFinishedLaunching() else { return }
        guard let path = AppIconSettings.resolvedImagePath(defaults: defaults),
              let prepareImageForPath = environment.prepareImageForPath else {
            AppIconSettings.applyIcon(
                AppIconSettings.resolvedMode(defaults: defaults),
                environment: environment
            )
            return
        }

        applyTask = Task { @MainActor [weak self] in
            defer { self?.finish(requestGeneration: requestGeneration) }
            guard !Task.isCancelled else { return }

            let prepared = await prepareImageForPath(path)
            guard !Task.isCancelled,
                  AppIconSettings.resolvedImagePath(defaults: defaults) == path else {
                return
            }

            guard let prepared else {
                AppIconSettings.applyIcon(
                    AppIconSettings.resolvedMode(defaults: defaults),
                    environment: environment
                )
                return
            }

            environment.stopAppearanceObservation()
            environment.setApplicationIconImage(prepared.image)
            environment.notifyDockTilePlugin()
        }
    }

    /// Cancels an in-flight custom-icon resolution without changing defaults.
    func cancel() {
        generation &+= 1
        applyTask?.cancel()
        applyTask = nil
    }

    private func finish(requestGeneration: UInt64) {
        guard generation == requestGeneration else { return }
        applyTask = nil
    }

    deinit {
        applyTask?.cancel()
    }
}
