import AppKit
import Carbon.HIToolbox

/// Calls `onChange` on main when the selected keyboard layout changes, also
/// while cmux is in the background. Distributed notifications are otherwise
/// held until the app is active again, which is too late for a system-wide
/// key.
///
/// One process-wide Core Foundation registration with
/// `.deliverImmediately` (the block form of `DistributedNotificationCenter`
/// has no suspension behavior), not a selector observer: a selector into
/// this main-actor class trapped when the notice arrived off main. The C
/// callback names no observer; it hops to main and calls every live one.
public final class KeyboardLayoutObserver {
    private let onChange: @MainActor () -> Void

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        Self.live.removeAll { $0.value == nil }
        Self.live.append(Weak(self))
        Self.registerOnce()
    }

    private struct Weak {
        weak var value: KeyboardLayoutObserver?
        init(_ value: KeyboardLayoutObserver) { self.value = value }
    }

    private static var live: [Weak] = []
    private static var registered = false

    private static func registerOnce() {
        guard !registered else { return }
        registered = true
        // No observer pointer (CF allows NULL): the registration is never removed and the callback
        // reads no context, so there is no object address for a late notice to reach.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            nil,
            keyboardLayoutDidChange,
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )
    }

    /// Calls every live observer (on main).
    static func layoutChanged() {
        live.removeAll { $0.value == nil }
        for observer in live.compactMap(\.value) { observer.onChange() }
    }
}

/// The Core Foundation callback (any thread): the observers run on main.
/// The order between two layout changes does not matter (each reload reads
/// the current layout), so a hop is enough.
nonisolated func keyboardLayoutDidChange(_ center: CFNotificationCenter?, _ observer: UnsafeMutableRawPointer?,
                                         _ name: CFNotificationName?, _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?) {
    // main-hop-allow: a C callback with no context reaches no scheduler; the one hop only fans the change out to the live observers
    Task { @MainActor in KeyboardLayoutObserver.layoutChanged() }
}
