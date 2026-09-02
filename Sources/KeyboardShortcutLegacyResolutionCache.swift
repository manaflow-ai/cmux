import CmuxFoundation
import Foundation

/// Caches the one legacy-default conflict decision used by the key-event path.
///
/// Voice's implicit default must scan persisted bindings to preserve upgrade
/// precedence, but that scan must not run for every key event. The cache is
/// lock-free and invalidated by shortcut/defaults notifications. Atomic
/// generation validation prevents a computation that races invalidation from
/// publishing a stale result.
final class KeyboardShortcutLegacyResolutionCache: @unchecked Sendable {
    private let generation = AtomicUInt64Generation()
    private let cachedGeneration = AtomicUInt64Value(UInt64.max)
    private let cachedValue = AtomicBooleanGate(false)
    private let hasCachedValue = AtomicBooleanGate(false)
    private let notificationCenter: NotificationCenter
    private var shortcutObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        shortcutObserver = notificationCenter.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
        defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let shortcutObserver {
            notificationCenter.removeObserver(shortcutObserver)
        }
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
    }

    func invalidate() {
        hasCachedValue.storeRelease(false)
        _ = generation.advanceRelaxed()
    }

    func value(resolving: () -> Bool) -> Bool {
        let requestedGeneration = generation.loadRelaxed()
        if hasCachedValue.loadAcquire(),
           cachedGeneration.loadRelaxed() == requestedGeneration {
            return cachedValue.loadAcquire()
        }

        let resolved = resolving()
        guard generation.loadRelaxed() == requestedGeneration else {
            return resolved
        }

        cachedValue.storeRelease(resolved)
        cachedGeneration.storeRelaxed(requestedGeneration)
        hasCachedValue.storeRelease(true)
        return resolved
    }
}
