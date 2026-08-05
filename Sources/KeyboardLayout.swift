import AppKit
import Carbon
import Foundation

@MainActor
enum KeyboardLayout {
    static let didChangeNotification = Notification.Name("KeyboardLayoutDidChange")

    /// Test-only override for the current input source ID.
    #if DEBUG
    static var debugInputSourceIdOverride: String?
    #endif

    @MainActor private static var inputSourceObserver: NSObjectProtocol?
    @MainActor private static let snapshotCache = KeyboardLayoutSnapshotCache(
        initialSnapshot: .usBootstrap,
        loader: {
            KeyboardLayoutSystemLoader.loadCurrentSnapshot()
        }
    ) { _ in
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Installs the sole process-wide TIS notification observer and starts an
    /// off-main load. The US bootstrap remains usable until the load wins.
    @MainActor
    static func start(
        distributedNotificationCenter: DistributedNotificationCenter = .default()
    ) {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = distributedNotificationCenter.addObserver(
            forName: Notification.Name(
                rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
            ),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                snapshotCache.replaceSnapshotWithoutInstalling(
                    snapshotCache.snapshot.replacingInputSourceID(nil)
                )
                snapshotCache.requestRefresh()
            }
        }
        snapshotCache.requestRefresh()
    }

    /// Return a string ID from the last completed input-source snapshot.
    static var id: String? {
        #if DEBUG
        if let override = debugInputSourceIdOverride { return override }
        #endif
        return currentSnapshot().inputSourceID
    }

    /// Translate a physical key code using the last completed snapshot.
    nonisolated static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        currentSnapshot().shortcutCharacter(
            forKeyCode: keyCode,
            modifierFlags: modifierFlags
        )
    }

    /// Captures one immutable snapshot for callers that scan many key codes.
    nonisolated static func shortcutCharacterProvider() -> (UInt16, NSEvent.ModifierFlags) -> String? {
        let snapshot = currentSnapshot()
        return { keyCode, modifierFlags in
            snapshot.shortcutCharacter(
                forKeyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }
    }

    /// Translate a physical key code exactly as text input would, including
    /// Option/Shift and without ASCII fallback.
    nonisolated static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        currentSnapshot().textInputCharacter(
            forKeyCode: keyCode,
            modifierFlags: modifierFlags
        )
    }

    #if DEBUG
    /// Test seam for layouts not enabled on the host. All TIS work stays on a
    /// detached utility task, matching the production loader.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        inputSourceID: String
    ) async -> String? {
        await Task.detached(priority: .utility) {
            KeyboardLayoutSystemLoader.textInputCharacter(
                forKeyCode: keyCode,
                modifierFlags: modifierFlags,
                inputSourceID: inputSourceID
            )
        }.value
    }
    #endif

    /// Return the ASCII-normalized equivalent of an event's characters,
    /// falling back through the cached ASCII-capable layout translation.
    nonisolated static func normalizedCharacters(for event: NSEvent) -> String {
        let raw = (event.charactersIgnoringModifiers ?? "").lowercased()
        if raw.allSatisfy(\.isASCII) { return raw }
        if let layoutCharacter = character(forKeyCode: event.keyCode) {
            return layoutCharacter
        }
        return raw
    }

    static func prepareOffMainSnapshotOperation<Output: Sendable>(
        _ operation: @escaping @Sendable () -> Output
    ) -> @Sendable () -> Output {
        let snapshot = currentSnapshot()
        return {
            KeyboardLayoutTaskSnapshot.$current.withValue(snapshot) {
                operation()
            }
        }
    }

    nonisolated private static func currentSnapshot() -> KeyboardLayoutSnapshot {
        if let taskSnapshot = KeyboardLayoutTaskSnapshot.current {
            return taskSnapshot
        }
        return MainActor.assumeIsolated {
            snapshotCache.snapshot
        }
    }
}
