import AppKit
import GhosttyKit

/// Owns the button sessions that a ``GhosttyNSView`` has sent to one native
/// Ghostty surface.
///
/// A session is bound to the runtime generation and native pointer that
/// received its press.  Releasing a session therefore requires the same
/// generation token; a later surface or press cannot be released by an older
/// event.  Pointer coordinates are kept in the same ledger so a synthesized
/// release uses the last event belonging to that surface.
final class GhosttyMouseSessionLedger {
    private(set) var activeSurface: SurfaceIdentity?
    private(set) var pointerState: PointerState?
    private var sessions: [Button: Session] = [:]
    private var nextGeneration: UInt64 = 0

    /// The buttons currently owned by this ledger.
    var activeButtons: Set<Button> {
        Set(sessions.keys)
    }

    /// Returns the sessions currently owned by `surface` in deterministic
    /// button order.
    func sessions(on surface: SurfaceIdentity?) -> [Session] {
        guard let surface else { return [] }
        return sessions.values
            .filter { $0.surface == surface }
            .sorted { lhs, rhs in
                lhs.button.ordering < rhs.button.ordering
            }
    }

    /// Whether the ledger owns a session for `button` on `surface`.
    func hasSession(
        for button: Button,
        on surface: SurfaceIdentity?
    ) -> Bool {
        guard let surface else { return false }
        return sessions[button]?.surface == surface
    }

    /// Returns the current session for `button` only when it belongs to
    /// `surface`.
    func session(
        for button: Button,
        on surface: SurfaceIdentity?
    ) -> Session? {
        guard let surface,
              let session = sessions[button],
              session.surface == surface else {
            return nil
        }
        return session
    }

    /// Changes the native-surface identity and invalidates sessions from the
    /// previous runtime.  This is the only transition that can replace the
    /// ledger's surface owner.
    @discardableResult
    func transition(to surface: SurfaceIdentity?) -> Bool {
        guard activeSurface != surface else { return false }
        let hadState = !sessions.isEmpty || pointerState != nil
        sessions.removeAll(keepingCapacity: true)
        pointerState = nil
        activeSurface = surface
        return hadState
    }

    /// Invalidates all pointer state, including a detached surface.
    func invalidate() {
        sessions.removeAll(keepingCapacity: true)
        pointerState = nil
        activeSurface = nil
    }

    /// Records the latest pointer snapshot for the current surface.
    ///
    /// Callers must transition the ledger before recording.  A mismatched
    /// snapshot is ignored rather than being allowed to move state to a
    /// replacement runtime implicitly.
    func rememberPointer(
        _ pointer: PointerState,
        on surface: SurfaceIdentity
    ) {
        guard activeSurface == surface else { return }
        pointerState = pointer
    }

    /// Starts a new button session on the current surface.
    @discardableResult
    func begin(
        _ button: Button,
        on surface: SurfaceIdentity
    ) -> Session? {
        guard activeSurface == surface else { return nil }
        nextGeneration &+= 1
        let session = Session(
            button: button,
            generation: nextGeneration,
            surface: surface
        )
        sessions[button] = session
        return session
    }

    /// Finishes a session only when its generation still owns the button.
    @discardableResult
    func finish(_ session: Session) -> Bool {
        guard sessions[session.button] == session else { return false }
        sessions.removeValue(forKey: session.button)
        return true
    }

    /// Finishes a button session by its generation token.
    @discardableResult
    func finish(
        _ button: Button,
        generation: UInt64
    ) -> Bool {
        guard let session = sessions[button],
              session.generation == generation else {
            return false
        }
        sessions.removeValue(forKey: button)
        return true
    }

    /// Returns sessions that should receive a synthesized release.
    ///
    /// `physicalButtons` is a reconciliation signal, not ownership state. It
    /// is supplied only from non-drag event boundaries; drag dispatch itself
    /// never consults it. Explicitly forced session tokens are always returned
    /// when they still belong to `surface`.
    func sessionsNeedingRepair(
        on surface: SurfaceIdentity,
        physicalButtons: Int?,
        forcedSessions: Set<Session>
    ) -> [Session] {
        guard activeSurface == surface else { return [] }
        return sessions.values
            .filter { session in
                forcedSessions.contains(session)
                    || physicalButtons.map {
                        ($0 & session.button.pressedMouseButtonsMask) == 0
                    } == true
            }
            .sorted { lhs, rhs in
                lhs.button.ordering < rhs.button.ordering
            }
    }
}
