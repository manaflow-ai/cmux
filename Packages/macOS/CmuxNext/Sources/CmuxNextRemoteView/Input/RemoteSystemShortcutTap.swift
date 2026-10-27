public import AppKit
import CmuxNextCompat
import CoreGraphics

/// The installed taps by the token each gives its event tap as `refcon`.
nonisolated let remoteSystemShortcutTapCallbacks = CallbackRegistry<RemoteSystemShortcutTap>(capacity: 8)

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
/// One instance for the app; the owner calls `remove()` itself. While the
/// tap is installed it keeps itself alive (`installedSelf`), so it keeps
/// working until `remove()` even if the owner lets go first. Its callback's
/// `refcon` is a `CallbackToken`, never the instance: a callback after
/// `remove()` lets the event through and is counted.
@MainActor
public final class RemoteSystemShortcutTap {
    /// The surface taken keys go to.
    public private(set) weak var surface: RemoteInputSurface?
    /// Whether the tap may keep taking keys (cheap: no permission checks).
    public var stillHolds: () -> Bool = { false }
    /// The tap removed itself (its conditions stopped holding, or it failed).
    public var onRemoved: (() -> Void)?
    private let makePort: RemoteEventTapPortFactory
    private var port: (any RemoteEventTapPort)?
    /// The port's `refcon`: this instance in `remoteSystemShortcutTapCallbacks` while `port` exists.
    private var token: CallbackToken?
    private var removalPending = false
    /// Self while `port` exists; `remove()` clears it after the port can no longer call back.
    private var installedSelf: RemoteSystemShortcutTap?

    public convenience init() {
        self.init(makePort: { mask, callback, refcon in
            unsafe QuartzEventTapPort(mask: mask, callback: callback, refcon: refcon)
        })
    }

    /// `makePort` creates the event tap (tests pass a fake).
    init(makePort: @escaping RemoteEventTapPortFactory) {
        self.makePort = makePort
    }

    public var isInstalled: Bool { port != nil }

    /// Installs the tap for `surface` (or points it there). False when macOS
    /// refused it (no Accessibility).
    @discardableResult
    public func install(for surface: RemoteInputSurface) -> Bool {
        self.surface = surface
        removalPending = false
        if port != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let token = try? remoteSystemShortcutTapCallbacks.register(self) else {
            self.surface = nil
            return false
        }
        // SAFETY: the refcon is a token, never dereferenced. The callback reads `event` only during its call.
        guard let port = unsafe makePort(
            mask,
            { _, type, event, refcon in
                // A token whose tap was removed lets the event through (the registry counts it).
                guard let tap = unsafe remoteSystemShortcutTapCallbacks.target(forContext: refcon) else {
                    // SAFETY: passes the event on unchanged at +0, as the tap API expects.
                    return unsafe CallbackToken.passingBack(event)
                }
                let key = RemoteTapKey(type: type, event: event)
                let rawType = type.rawValue
                // main-proof: QuartzEventTapPort adds the tap's run loop source to the main run loop only
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let type = CGEventType(rawValue: rawType) else { return false }
                    return tap.handle(type, key)
                }
                // SAFETY: nil drops the event; otherwise it passes on unchanged at +0.
                return taken ? nil : unsafe CallbackToken.passingBack(event)
            },
            token.context
        ) else {
            remoteSystemShortcutTapCallbacks.unregister(token)
            self.surface = nil
            return false
        }
        self.port = port
        self.token = token
        installedSelf = self
        return true
    }

    /// Removes the tap now; keys go to macOS and the app as usual.
    public func remove() {
        removalPending = false
        surface = nil
        guard let port else { return }
        port.invalidate()
        self.port = nil
        // The port can no longer call back: the token and the instance may go now.
        // The caller holds the instance for the rest of this method.
        if let token { remoteSystemShortcutTapCallbacks.unregister(token) }
        token = nil
        installedSelf = nil
        onRemoved?()
    }

    /// One event from the tap (`key`: its key down or up, read in the callback): true when it
    /// was sent to the other Mac (consumed).
    private func handle(_ type: CGEventType, _ key: RemoteTapKey?) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off (a slow callback, or input it guards): on again while it still holds.
            if let port, stillHolds() { port.enable() } else { removeSoon() }
            return false
        default:
            break
        }
        guard let key else { return false }
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
        // main-hop-allow: an event tap may not invalidate its own run loop source inside its callback, so the removal is the next main turn; until then every event asks stillHolds and passes through. The tap is made in a property initializer (MacScreenSystemShortcuts) with no scheduler
        Task { @MainActor [weak self] in
            guard let self, removalPending else { return }
            remove()
        }
    }
}
