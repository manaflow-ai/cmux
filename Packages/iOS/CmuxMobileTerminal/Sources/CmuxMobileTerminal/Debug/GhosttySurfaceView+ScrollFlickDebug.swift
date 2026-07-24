#if canImport(UIKit) && DEBUG
import CmuxMobileDiagnostics
import GhosttyKit
import UIKit

/// Scripted flick harness for scroll-performance verification on simulators,
/// where no tool can synthesize real touch drags. It drives the transparent
/// scroll-mechanics view's content offset per display-link frame with a
/// decaying velocity, so everything below the gesture recognizer — offset
/// deltas, per-frame coalescing, local mirror scroll, delegate forwarding —
/// runs exactly as it does under a finger.
///
/// Trigger from the host with Darwin notifications (no payload channel, so
/// impulses are fixed and stack like repeated flicks):
///
///     xcrun simctl spawn <udid> notifyutil -p com.cmux.debug.scrollflick.up.fast
///     xcrun simctl spawn <udid> notifyutil -p com.cmux.debug.scrollflick.up.slow
///     xcrun simctl spawn <udid> notifyutil -p com.cmux.debug.scrollflick.down.fast
///     xcrun simctl spawn <udid> notifyutil -p com.cmux.debug.scrollflick.down.slow
///     xcrun simctl spawn <udid> notifyutil -p com.cmux.debug.scrollflick.stop
extension GhosttySurfaceView {
    private enum DebugScrollFlick {
        static let fastImpulsePointsPerSecond: CGFloat = 12000
        static let slowImpulsePointsPerSecond: CGFloat = 2500
        /// Exponential decay rate per second; distance = impulse / decay.
        static let decayPerSecond: CGFloat = 0.9
        static let restVelocity: CGFloat = 24
        nonisolated(unsafe) static var installed = false
    }

    static func installDebugScrollFlickTriggerIfNeeded() {
        guard !DebugScrollFlick.installed else { return }
        DebugScrollFlick.installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let names: [(String, CGFloat)] = [
            ("com.cmux.debug.scrollflick.up.fast", DebugScrollFlick.fastImpulsePointsPerSecond),
            ("com.cmux.debug.scrollflick.up.slow", DebugScrollFlick.slowImpulsePointsPerSecond),
            ("com.cmux.debug.scrollflick.down.fast", -DebugScrollFlick.fastImpulsePointsPerSecond),
            ("com.cmux.debug.scrollflick.down.slow", -DebugScrollFlick.slowImpulsePointsPerSecond),
            ("com.cmux.debug.scrollflick.stop", 0),
        ]
        for (name, _) in names {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String? else { return }
                    Task { @MainActor in
                        GhosttySurfaceView.applyDebugScrollFlick(named: raw)
                    }
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private static func applyDebugScrollFlick(named name: String) {
        let impulse: CGFloat
        switch name {
        case "com.cmux.debug.scrollflick.up.fast":
            impulse = DebugScrollFlick.fastImpulsePointsPerSecond
        case "com.cmux.debug.scrollflick.up.slow":
            impulse = DebugScrollFlick.slowImpulsePointsPerSecond
        case "com.cmux.debug.scrollflick.down.fast":
            impulse = -DebugScrollFlick.fastImpulsePointsPerSecond
        case "com.cmux.debug.scrollflick.down.slow":
            impulse = -DebugScrollFlick.slowImpulsePointsPerSecond
        default:
            impulse = 0
        }
        // The mounted, on-screen surface owns the flick. Several surface views
        // can be registered at once (detached transitions, hidden mounts), so
        // log every candidate and pick the largest visibly-mounted one.
        let views = registeredSurfaceViews.values.compactMap(\.value)
        for (index, candidate) in views.enumerated() {
            MobileDebugLog.anchormux(
                "debug.scrollflick.candidate \(index) surface=\(candidate.hostSurfaceID ?? "nil") "
                + "window=\(candidate.window != nil) hidden=\(candidate.isHidden) "
                + "alpha=\(candidate.alpha) bounds=\(Int(candidate.bounds.width))x\(Int(candidate.bounds.height)) "
                + "offset=\(candidate.debugLastScrollbar?.offset ?? -1) total=\(candidate.debugLastScrollbar?.total ?? -1)"
            )
        }
        let mounted = views.filter {
            $0.window != nil && !$0.isHidden && $0.alpha > 0.01
                && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        guard let view = mounted.max(by: {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }) else {
            MobileDebugLog.anchormux("debug.scrollflick no_visible_surface name=\(name)")
            return
        }
        if impulse == 0 {
            view.debugScrollFlickVelocity = 0
        } else {
            view.debugScrollFlickVelocity += impulse
        }
        view.debugScrollFlickLastTime = CACurrentMediaTime()
        MobileDebugLog.anchormux(
            "debug.scrollflick impulse=\(Int(impulse)) velocity=\(Int(view.debugScrollFlickVelocity)) "
            + "contents=\(view.debugRendererContentsIdentity())"
        )
    }

    /// Advances the scripted flick by one display-link frame: moves the
    /// scroll-mechanics offset (which fires the production scrollViewDidScroll
    /// -> delta coalescing -> local scroll path) and decays the velocity like
    /// UIKit deceleration.
    func advanceDebugScrollFlickIfNeeded(now: CFTimeInterval) {
        guard debugScrollFlickVelocity != 0 else { return }
        let dt = CGFloat(max(0, min(now - debugScrollFlickLastTime, 0.1)))
        debugScrollFlickLastTime = now
        guard dt > 0 else { return }
        let delta = debugScrollFlickVelocity * dt
        // Positive velocity = toward older content = finger dragging down =
        // decreasing content offset.
        scrollMechanicsView.contentOffset.y -= delta
        debugScrollFlickVelocity *= exp(-DebugScrollFlick.decayPerSecond * dt)
        if abs(debugScrollFlickVelocity) < DebugScrollFlick.restVelocity {
            debugScrollFlickVelocity = 0
            MobileDebugLog.anchormux(
                "debug.scrollflick.rest offset=\(debugLastScrollbar?.offset ?? -1) "
                + "needsDraw=\(needsDraw) renderInFlight=\(renderInFlight) "
                + "suppressed=\(isRenderDispatchSuppressed) "
                + "verifiedSuppressed=\(verifiedReplayRenderSuppressed) "
                + "recoveryPaused=\(renderPipelineRecoveryPaused) frozen=\(verifiedReplayFrozenPresentationLayer != nil)"
            )
            var surfaceSize = "nil"
            if let surface {
                let size = ghostty_surface_size(surface)
                surfaceSize = "\(size.columns)x\(size.rows) px=\(size.width_px)x\(size.height_px) cell=\(size.cell_width_px)x\(size.cell_height_px)"
            }
            let layers = (layer.sublayers ?? []).map { sub in
                "\(type(of: sub)) b=\(Int(sub.bounds.width))x\(Int(sub.bounds.height)) "
                + "f=\(Int(sub.frame.minX)),\(Int(sub.frame.minY)),\(Int(sub.frame.width))x\(Int(sub.frame.height)) "
                + "scale=\(sub.contentsScale) hidden=\(sub.isHidden) contents=\(sub.contents != nil)"
            }.joined(separator: " | ")
            MobileDebugLog.anchormux(
                "debug.scrollflick.layers host=\(type(of: layer)) b=\(Int(layer.bounds.width))x\(Int(layer.bounds.height)) "
                + "scale=\(layer.contentsScale) surf=\(surfaceSize) contents=\(debugRendererContentsIdentity()) "
                + "children=[\(layers)]"
            )
        }
    }

    /// Identity of the renderer layer's current contents (the presented
    /// IOSurface). Consecutive samples that never change while renders run
    /// prove presents are being dropped before layer assignment.
    func debugRendererContentsIdentity() -> String {
        guard let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer) else {
            return "no-renderer-layer"
        }
        var active = "?"
        if let cls = object_getClass(renderer),
           let ivar = class_getInstanceVariable(cls, "surface_updates_active") {
            let offset = ivar_getOffset(ivar)
            let raw = Unmanaged.passUnretained(renderer).toOpaque()
                .advanced(by: offset)
                .assumingMemoryBound(to: UnsafeRawPointer?.self)
                .pointee
            active = raw != nil ? "1" : "0"
        }
        guard let contents = renderer.contents else { return "nil active=\(active)" }
        return "\(UInt(bitPattern: ObjectIdentifier(contents as AnyObject).hashValue)) active=\(active)"
    }
}
#endif
