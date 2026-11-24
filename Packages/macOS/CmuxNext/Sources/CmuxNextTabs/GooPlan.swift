import CCmuxMotionFFI
import CoreGraphics
import Foundation
import os

/// One goo event's keyframes (plans/cmux-next/gooey-tabs.md, "The C ABI"): cmux-motion's `cmux_goo_plan` sampled
/// once, its outlines as `CGPath`s (one per keyframe, nothing per frame), for Core Animation to play. Rust owns
/// the springs, the stretch, the lean and the wobble; this only carries the numbers across.
struct GooPlan {
    /// The blob's outline per keyframe, in the strip's tabs coordinates (flipped: y grows down to the card).
    var paths: [CGPath]
    /// Each keyframe's time, 0...1 of ``duration``.
    var keyTimes: [NSNumber]
    /// Seconds; 0 under reduced motion (one keyframe, the end).
    var duration: Double // motion: allow the goo plan's own length, from cmux-motion's springs, not a token
    /// Media time the plan starts at: the later of its two tracks' starts.
    var begin: Double
    /// The edges' tracks the plan sampled: the next event retargets these from its own now.
    var left: CmuxGooTrack
    var right: CmuxGooTrack
}

/// A strip's door to cmux-motion's goo (one per ``TabStripGoo``): its reused outline buffer, so a plan allocates no
/// outline storage, and its count of FFI calls (`GooStripTests`: the plan never walks the tabs).
@MainActor
final class GooPlanner {
    /// The keyframes' sampling rate: Core Animation interpolates between them on a 120 Hz display.
    static let hz = 60.0
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "goo")
    private(set) var calls = 0
    private var outlines = [CmuxGooOutline](repeating: CmuxGooOutline(), count: Int(CMUX_GOO_KEYFRAMES_MAX))
    private var times = [Double](repeating: 0, count: Int(CMUX_GOO_KEYFRAMES_MAX))

    func resetCalls() { calls = 0 }

    /// `event`'s plan from `from` to `to` on the `left` and `right` tracks (already retargeted by the caller).
    func plan(_ event: CmuxGooEvent, from: CmuxGooBlob, to: CmuxGooBlob, left: CmuxGooTrack, right: CmuxGooTrack,
              tuning: CmuxGooTuning, reduceMotion: Bool) -> GooPlan {
        let interval = Self.signposter.beginInterval("goo.plan")
        defer { Self.signposter.endInterval("goo.plan", interval) }
        var (from, to, left, right, tuning) = (from, to, left, right, tuning)
        var seconds = 0.0
        let count = outlines.withUnsafeMutableBufferPointer { outs in
            times.withUnsafeMutableBufferPointer { keys in
                cmux_goo_plan(event, &from, &to, &left, &right, &tuning, Self.hz, reduceMotion, outs.baseAddress,
                              keys.baseAddress, outs.count, &seconds)
            }
        }
        calls += 1
        let n = min(Int(count), outlines.count)
        return GooPlan(paths: (0..<n).map { Self.path(outlines[$0]) }, keyTimes: (0..<n).map { NSNumber(value: times[$0]) },
                       duration: n > 1 ? seconds : 0, begin: max(left.start, right.start), left: left, right: right)
    }

    /// `track` restarted at `t` from its state there toward `target` on `spring`, its velocity kept: a new event
    /// mid-animation never snaps (the interruption rule).
    func retarget(_ track: CmuxGooTrack, at t: Double, to target: Double, spring: CmuxGooSpring) -> CmuxGooTrack {
        var track = track
        calls += 1
        return cmux_goo_track_retarget(&track, t, target, spring)
    }

    /// Media time when `track` comes to rest: its start plus the seconds until its offset and velocity fall under
    /// half a point (and half a point per second), from cmux-motion's spring.
    func restTime(_ track: CmuxGooTrack) -> Double {
        var track = track
        calls += 1
        return track.start + cmux_goo_track_rest_time(&track, 0.5)
    }

    /// `track`'s position and velocity at media time `t`.
    func state(_ track: CmuxGooTrack, at t: Double) -> (x: Double, v: Double) {
        var track = track, x = 0.0, v = 0.0
        calls += 1
        cmux_goo_track_state(&track, t, &x, &v)
        return (x, v)
    }

    /// The blob at rest (equals `TabCell.folderPath`'s shape to under half a pixel).
    func restPath(_ blob: CmuxGooBlob) -> CGPath {
        var blob = blob, out = CmuxGooOutline()
        calls += 1
        cmux_goo_blob_outline(&blob, &out)
        return Self.path(out)
    }

    /// The blob merged with a hovered neighbour's pill (full only), or the blob alone past the goo threshold.
    func neck(_ blob: CmuxGooBlob, with pill: CGRect, radius: Double, tuning: CmuxGooTuning) -> CGPath {
        var blob = blob, tuning = tuning, out = CmuxGooOutline()
        calls += 1
        cmux_goo_neck(&blob, pill.minX, pill.minY, pill.width, pill.height, radius, &tuning, &out)
        return Self.path(out)
    }

    /// The drag neck: the slot's blob joined to the lifted tab while it holds, the slot alone once it snapped.
    func dragNeck(slot: CmuxGooBlob, tab: CGRect, wasAttached: Bool, tuning: CmuxGooTuning) -> (path: CGPath, attached: Bool) {
        var slot = slot, tuning = tuning, out = CmuxGooOutline(), attached = wasAttached
        calls += 1
        cmux_goo_drag_neck(&slot, tab.minX, tab.minY, tab.width, tab.height, wasAttached, &tuning, &out, &attached)
        return (Self.path(out), attached)
    }

    /// An outline as a closed path of its fixed count of cubics, so any two interpolate.
    nonisolated static func path(_ outline: CmuxGooOutline) -> CGPath {
        withUnsafeBytes(of: outline.p) { raw in
            let p = raw.bindMemory(to: CmuxGooPoint.self)
            func point(_ i: Int) -> CGPoint { CGPoint(x: p[i].x, y: p[i].y) }
            let path = CGMutablePath()
            guard !p.isEmpty else { return path }
            path.move(to: point(0))
            var i = 1
            while i + 2 < p.count {
                path.addCurve(to: point(i + 2), control1: point(i), control2: point(i + 1))
                i += 3
            }
            path.closeSubpath()
            return path
        }
    }
}

nonisolated extension GooSpring {
    /// The spring the C ABI hands back.
    init(_ ffi: CmuxGooSpring) { self.init(response: ffi.response, dampingFraction: ffi.damping_fraction) }

    /// The spring as the C ABI takes it.
    var ffi: CmuxGooSpring { CmuxGooSpring(response: response, damping_fraction: dampingFraction) }
}

nonisolated extension GooTuning {
    /// The tuning the C ABI hands back, field for field.
    init(_ ffi: CmuxGooTuning) {
        self.init(select: GooSpring(ffi.select), open: GooSpring(ffi.open), close: GooSpring(ffi.close),
                  reorder: GooSpring(ffi.reorder), snap: GooSpring(ffi.snap), absorb: GooSpring(ffi.absorb),
                  wobble: GooSpring(ffi.wobble), stretch: ffi.stretch, lean: ffi.lean, feetScale: ffi.feet_scale,
                  k: ffi.k, breakDistance: ffi.break_distance, captureDistance: ffi.capture_distance,
                  wobbleAmplitude: ffi.wobble_amplitude)
    }

    /// The tuning as the C ABI takes it, field for field.
    var ffi: CmuxGooTuning {
        CmuxGooTuning(select: select.ffi, open: open.ffi, close: close.ffi, reorder: reorder.ffi, snap: snap.ffi,
                      absorb: absorb.ffi, wobble: wobble.ffi, stretch: stretch, lean: lean, feet_scale: feetScale,
                      k: k, break_distance: breakDistance, capture_distance: captureDistance,
                      wobble_amplitude: wobbleAmplitude)
    }
}
