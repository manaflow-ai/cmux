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
final class KeyboardLayoutObserver {
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
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
    /// The identity of the one registration (CF keys observers by pointer).
    private static let registration = NSObject()

    private static func registerOnce() {
        guard !registered else { return }
        registered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(registration).toOpaque(),
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
    Task { @MainActor in KeyboardLayoutObserver.layoutChanged() }
}
