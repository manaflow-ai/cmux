import AppKit
import CmuxSettings
import CmuxSettingsUI

/// Owns the app-wide live chrome palette snapshot and fans it out to window
/// owners. JSON/UserDefaults streams are the mutation source; views consume
/// immutable snapshots through SwiftUI environment values.
@MainActor
final class ChromePaletteRuntimeCoordinator {
    private let runtime: SettingsRuntime
    private let resolver: ChromePaletteRuntimeResolver
    private var onPaletteChange: @MainActor (ChromePalette) -> Void
    private var themeTask: Task<Void, Never>?
    private var overridesTask: Task<Void, Never>?
    private var appearanceTask: Task<Void, Never>?
    private var systemAppearanceTask: Task<Void, Never>?
    private var updateSubscribers: [UUID: AsyncStream<ChromePalette>.Continuation] = [:]

    private var theme: ChromeThemeID
    private var overrides: ChromeTokenOverrides
    private var appearance: CmuxSettings.AppearanceMode
    private(set) var palette: ChromePalette

    /// Creates a coordinator that publishes palette snapshots to `onPaletteChange`.
    ///
    /// - Parameters:
    ///   - runtime: The app's settings dependency bundle.
    ///   - onPaletteChange: Main-actor sink for each effective palette change.
    init(
        runtime: SettingsRuntime,
        onPaletteChange: @escaping @MainActor (ChromePalette) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.resolver = ChromePaletteRuntimeResolver(runtime: runtime)
        self.onPaletteChange = onPaletteChange
        self.theme = runtime.jsonStore.snapshotValue(for: runtime.catalog.chrome.theme)
        self.overrides = runtime.jsonStore.snapshotValue(for: runtime.catalog.chrome.overrides)
        self.appearance = runtime.userDefaultsStore.initialValue(for: runtime.catalog.app.appearance)
        self.palette = ChromePalette.resolve(
            theme: theme,
            appearanceMode: appearance,
            effectiveSystemScheme: resolver.effectiveSystemScheme,
            overrides: overrides
        )
    }

    /// Installs the application sink after composition-root dependencies are
    /// initialized. Keeping this separate from ``init`` lets an `App` wire the
    /// coordinator to its `NSApplicationDelegateAdaptor` without capturing the
    /// partially initialized `App` value.
    ///
    /// - Parameter handler: Main-actor callback invoked for each new palette.
    func setPaletteChangeHandler(
        _ handler: @escaping @MainActor (ChromePalette) -> Void
    ) {
        onPaletteChange = handler
    }

    deinit {
        themeTask?.cancel()
        overridesTask?.cancel()
        appearanceTask?.cancel()
        systemAppearanceTask?.cancel()
        for continuation in updateSubscribers.values {
            continuation.finish()
        }
    }

    /// Creates a stream of immutable palette snapshots for one UI consumer.
    ///
    /// The current palette is yielded immediately, followed by every later
    /// change. Each caller receives an independent stream, so consumers do not
    /// share a notification channel or mutable palette state.
    func makeUpdateStream() -> AsyncStream<ChromePalette> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<ChromePalette>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateSubscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeUpdateSubscriber(subscriberID)
            }
        }
        continuation.yield(palette)
        return stream
    }

    /// Starts the three typed setting streams and the system-appearance feed.
    /// Calling this more than once is harmless.
    func start() {
        guard themeTask == nil, overridesTask == nil, appearanceTask == nil else { return }
        publishIfNeeded()

        let catalog = runtime.catalog
        let themeStream = runtime.jsonStore.values(for: catalog.chrome.theme)
        themeTask = Task { [weak self] in
            for await theme in themeStream {
                guard !Task.isCancelled else { break }
                self?.theme = theme
                self?.publishIfNeeded()
            }
        }

        let overridesStream = runtime.jsonStore.values(for: catalog.chrome.overrides)
        overridesTask = Task { [weak self] in
            for await overrides in overridesStream {
                guard !Task.isCancelled else { break }
                self?.overrides = overrides
                self?.publishIfNeeded()
            }
        }

        let appearanceStream = runtime.userDefaultsStore.values(for: catalog.app.appearance)
        appearanceTask = Task { [weak self] in
            for await appearance in appearanceStream {
                guard !Task.isCancelled else { break }
                self?.appearance = appearance
                self?.publishIfNeeded()
            }
        }

        let systemAppearanceNotifications = NotificationCenter.default.notifications(
            named: .systemAppearanceDidChange
        )
        systemAppearanceTask = Task { [weak self] in
            for await _ in systemAppearanceNotifications {
                guard !Task.isCancelled else { break }
                self?.publishIfNeeded()
            }
        }
    }

    /// Stops all streams and removes the system appearance observer.
    func stop() {
        themeTask?.cancel()
        themeTask = nil
        overridesTask?.cancel()
        overridesTask = nil
        appearanceTask?.cancel()
        appearanceTask = nil
        systemAppearanceTask?.cancel()
        systemAppearanceTask = nil
    }

    /// Re-resolves the palette after an external lifecycle signal changes the
    /// effective system appearance without emitting a setting value.
    func refresh() {
        publishIfNeeded()
    }

    private func publishIfNeeded() {
        let next = ChromePalette.resolve(
            theme: theme,
            appearanceMode: appearance,
            effectiveSystemScheme: resolver.effectiveSystemScheme,
            overrides: overrides
        )
        guard next != palette else { return }
        palette = next
        for continuation in updateSubscribers.values {
            continuation.yield(next)
        }
        onPaletteChange(next)
    }

    private func removeUpdateSubscriber(_ id: UUID) {
        updateSubscribers.removeValue(forKey: id)?.finish()
    }
}
