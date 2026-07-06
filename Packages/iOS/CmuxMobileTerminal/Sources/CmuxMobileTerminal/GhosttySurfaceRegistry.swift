import GhosttyKit
import UIKit

/// The surface-pointer → view registry and its registry-scoped reads, split
/// out of `GhosttySurfaceView.swift` so the lookup machinery and the "View as
/// Text" capture live in one cohesive file. Everything here is `internal`
/// (not `private`) only so the main class file's lifecycle/snapshot paths can
/// keep using the registry across the file boundary; nothing is exported
/// beyond the module except `copyableTerminalText(surfaceID:)`.
final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttySurfaceView?

    init(_ value: GhosttySurfaceView) {
        self.value = value
    }
}

extension GhosttySurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttySurfaceView? {
        let identifier = surfaceIdentifier(for: surface)
        guard let view = registeredSurfaceViews[identifier]?.value else {
            registeredSurfaceViews.removeValue(forKey: identifier)
            return nil
        }
        return view
    }

    @MainActor
    @discardableResult
    public static func focusMountedInput(surfaceID: String, sceneID: ObjectIdentifier?) -> Bool {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        let matchingView = registeredSurfaceViews
            .sorted { $0.key < $1.key }
            .compactMap(\.value.value)
            .first { candidate in
                candidate.hostSurfaceID == surfaceID && candidate.window != nil
                    && (sceneID == nil || candidate.window?.windowScene.map(ObjectIdentifier.init) == sceneID)
                    && !candidate.isHidden && candidate.alpha > 0.01
            }
        guard let matchingView else { return false }
        matchingView.focusInput()
        return true
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }

    /// Full-content capture for the "View as Text" copy sheet: the SCREEN
    /// range (scrollback history plus every written row) of the on-screen
    /// terminal surface, read entirely on the phone's own libghostty surface —
    /// no Mac round-trip, works offline.
    ///
    /// Same threading contract as ``visibleTerminalSnapshot()``: the read runs
    /// on the serial `outputQueue` because `ghostty_surface_read_text` takes
    /// the surface lock that `process_output` holds during a render storm, so
    /// a main-thread read would stall the present and blank the terminal.
    /// The await is bounded by the surface's display-link deadline, like the
    /// diagnostic visible snapshot path, so a wedged output queue resumes nil
    /// instead of leaving the copy sheet loading forever.
    ///
    /// The continuation body enqueues on `outputQueue` synchronously while
    /// still on the main actor, so the read is FIFO-ordered before any
    /// later-enqueued `disposeSurface` free of the same pointer — the same
    /// lifetime argument `visibleTerminalSnapshot()` relies on.
    ///
    /// The bytes read are bounded at the source: iOS surfaces are created with
    /// `scrollback-limit = 2000000` (see `GhosttyRuntime.applyiOSDefaults`),
    /// so the SCREEN range can never materialize more than ~2MB of text no
    /// matter how long the session ran. The sheet's 5000-line budget is then
    /// applied off-main on top of that hard cap.
    ///
    /// - Parameter surfaceID: The shell-level surface/terminal id the caller
    ///   wants text for (the same id the mounting representable stamped on the
    ///   view as ``hostSurfaceID``). The lookup is scoped to that id so a
    ///   second visible surface — another iPad scene, an in-flight transition —
    ///   can never leak a different workspace's terminal into the capture.
    /// - Returns: The surface's screen text, or nil when that terminal has no
    ///   mounted surface or the read fails.
    public static func copyableTerminalText(surfaceID: String) async -> String? {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        // Scoped pick: only views stamped with the requested id qualify, and
        // only while actually on screen (same visibility filter as
        // `visibleTerminalSnapshot()`). A dismantling view can linger in the
        // registry with a non-nil surface until its queued dispose runs, and
        // its content stops at whenever its byte stream detached — prefer the
        // sheet's honest empty state over silently copying that stale text.
        // If the same terminal is mounted in several scenes the contents are
        // identical, so the lowest-keyed visible match keeps the pick
        // deterministic.
        let matchingView = registeredSurfaceViews
            .sorted { $0.key < $1.key }
            .compactMap(\.value.value)
            .first { candidate in
                candidate.hostSurfaceID == surfaceID && candidate.surface != nil
                    && candidate.window != nil && !candidate.isHidden
                    && candidate.alpha > 0.01
            }
        guard let matchingView,
              let surface = matchingView.surface else { return nil }
        return await matchingView.copyableTextForCurrentSurface(surface: surface)
    }

}
