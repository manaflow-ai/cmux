import Foundation
import QuartzCore

/// One additive component of an animated property: `delta * (1 - progress(t - start))`.
/// It starts `delta` away from the model value and ends at 0. Live, each
/// component is one Core Animation animation committed once when its event
/// happens; the render server interpolates it, so the main thread renders only
/// on events. A second event adds components on top of the running ones, so
/// position and velocity carry over (no snap). `offset(at:)` evaluates the
/// same closed form (tests, flight retargeting).
nonisolated struct MotionComponent: Sendable, Equatable {
    let id: Int
    let start: Double
    let delta: CGFloat
    let timing: TranscriptTiming

    init(id: Int, start: Double, delta: CGFloat, timing: TranscriptTiming) {
        self.id = id
        self.start = start
        self.delta = delta
        self.timing = timing
    }

    func offset(at t: Double) -> CGFloat { delta * CGFloat(1 - timing.progress(t - start)) }
    func done(at t: Double) -> Bool { t - start > timing.settle }
    var end: Double { start + timing.settle }
}

extension Array where Element == MotionComponent {
    func offset(at t: Double) -> CGFloat { reduce(0) { $0 + $1.offset(at: t) } }
    /// Largest distance the components can move a layer (visibility margin).
    var reach: CGFloat { reduce(0) { $0 + abs($1.delta) } }
    var end: Double { map(\.end).max() ?? -1 }
}

/// Hands out component ids and commits components to layers once each.
@MainActor
final class MotionCommitter {
    private var nextID = 0
    /// Animations committed since launch (bench: render-server work per send).
    private(set) var committed = 0

    func make(start: Double, delta: CGFloat, timing: TranscriptTiming) -> MotionComponent {
        nextID += 1
        return MotionComponent(id: nextID, start: start, delta: delta, timing: timing)
    }

    /// Adds the components `layer` does not carry yet. `scale` maps component
    /// units to the key path's units; `now` is the media time of this commit.
    func attach(_ components: [MotionComponent], to layer: CALayer, keyPath: String, scale: CGFloat, now: Double,
                tag: MotionTag) {
        guard !components.isEmpty else { return }
        let base = layer.convertTime(now, from: nil)
        var have = tag.ids[keyPath] ?? []
        for component in components where !have.contains(component.id) && !component.done(at: now) {
            let animation = component.timing.animation(keyPath: keyPath, delta: component.delta * scale)
            animation.beginTime = base + (component.start - now)
            layer.add(animation, forKey: "m\(component.id).\(keyPath)")
            have.insert(component.id)
            committed += 1
        }
        tag.ids[keyPath] = have
    }

    /// Removes every component animation `tag` recorded on `layer` (recycling).
    func clear(_ layer: CALayer, tag: MotionTag) {
        for (path, ids) in tag.ids { for id in ids { layer.removeAnimation(forKey: "m\(id).\(path)") } }
        tag.ids.removeAll()
    }
}

/// Which components a layer already carries, per key path.
@MainActor
final class MotionTag {
    var ids: [String: Set<Int>] = [:]
}
