public import AppKit
import CoreGraphics

/// A session keyboard event tap that takes system chords (Cmd-Tab,
/// Cmd-Space, Control-arrows, Cmd-Q ...) before macOS acts on them and
/// sends them through a remote input surface instead, so they reach the
/// other Mac ("Send System Shortcuts to the Remote Mac"). Which chords:
/// `RemoteSystemShortcuts`. Everything else passes through unchanged and
/// reaches the app as usual, so ordinary typing, modifiers (`flagsChanged`)
/// and the release chord keep going through the capture view.
///
/// It needs Accessibility (a session tap that can drop events). The owner
/// installs it only while its conditions hold and removes it as soon as one
/// stops; `stillHolds` is asked on every event too, so a missed notification
/// never leaves it taking keys. The callback runs on the main run loop and
/// does no blocking work. While Secure Event Input is on (a password field
/// anywhere), macOS hides keys from every tap: the chords then act on this
/// Mac as they do without the setting, and nothing fights it.
///
/// One instance for the app: the owner keeps it alive for the app's life
/// (the tap's callback holds it unretained) and calls `remove()` itself.
@MainActor
public final class RemoteSystemShortcutTap {
    /// The surface taken keys go to.
    public private(set) weak var surface: RemoteInputSurface?
    /// Whether the tap may keep taking keys (cheap: no permission checks).
    public var stillHolds: () -> Bool = { false }
    /// The tap removed itself (its conditions stopped holding, or it failed).
    public var onRemoved: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var removalPending = false

    public init() {}

    public var isInstalled: Bool { port != nil }

    /// Installs the tap for `surface` (or points it there). False when macOS
    /// refused it (no Accessibility).
    @discardableResult
    public func install(for surface: RemoteInputSurface) -> Bool {
        self.surface = surface
        removalPending = false
        if port != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tapAddress = Int(bitPattern: refcon)
                let eventAddress = Int(bitPattern: Unmanaged.passUnretained(event).toOpaque())
                let rawType = type.rawValue
                // main-proof: install adds the tap's run loop source to the main run loop only
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let tapPointer = UnsafeRawPointer(bitPattern: tapAddress),
                          let eventPointer = UnsafeRawPointer(bitPattern: eventAddress),
                          let type = CGEventType(rawValue: rawType) else { return false }
                    let tap = Unmanaged<RemoteSystemShortcutTap>.fromOpaque(tapPointer).takeUnretainedValue()
                    return tap.handle(type, Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue())
                }
                return taken ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.surface = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    /// Removes the tap now; keys go to macOS and the app as usual.
    public func remove() {
        removalPending = false
        surface = nil
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        onRemoved?()
    }

    /// One event from the tap: true when it was sent to the other Mac (consumed).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off (a slow callback, or input it guards): on again while it still holds.
            if let port, stillHolds() { CGEvent.tapEnable(tap: port, enable: true) } else { removeSoon() }
            return false
        default:
            break
        }
        guard let key = RemoteTapKey(type: type, event: event) else { return false }
        guard let surface, stillHolds() else {
            removeSoon()
            return false
        }
        return surface.takeSystemKey(key)
    }

    /// Removal from inside the tap's own callback waits for the callback to return.
    private func removeSoon() {
        guard !removalPending else { return }
        removalPending = true
        // task-owner: one removal after the tap callback that found its conditions gone
        Task { @MainActor [weak self] in
            guard let self, removalPending else { return }
            remove()
        }
    }
}
