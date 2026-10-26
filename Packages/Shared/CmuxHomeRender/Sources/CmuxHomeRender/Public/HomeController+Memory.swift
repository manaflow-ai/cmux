/// The controller's caches for the host's memory policy, with no platform type: the Mac registers
/// them with its memory coordinator (CmuxNextHome's `HomeRenderMemoryConsumer`); iOS sizes them
/// once with `memoryBudget`.
///
/// Everything dropped here is lossless. A row on screen keeps the bitmap and picture its layers
/// show; the next miss draws or loads it again off the main actor.
extension HomeController {
    /// The bytes the caches hold now: row bitmaps and decoded pictures (pixel bytes) and text
    /// measurements (estimated). Read from counters, never a walk.
    public var memoryBytes: Int {
        scene.bitmaps.bytes + scene.media.bytes + builder.measure.bytes
    }

    /// The entries the caches hold now (bitmaps, pictures and measurements).
    public var memoryEntryCount: Int {
        scene.bitmaps.count + scene.media.count + builder.measure.count
    }

    /// Frees now down to `fraction` of ``memoryBytes``, the oldest bitmaps and pictures first.
    /// Measurements, which every commit reads, go only when the bitmaps and pictures alone cannot
    /// reach the target, so `0` drops everything. The budget stays as it is.
    ///
    /// - Parameter fraction: The share of what the caches hold now to keep, 0...1 (NaN keeps all).
    public func trim(toFraction fraction: Double) {
        guard !fraction.isNaN else { return }
        let total = memoryBytes
        let target = CrashGuard.int(Double(total) * min(max(fraction, 0), 1), in: 0...total)
        let pictures = scene.bitmaps.bytes + scene.media.bytes
        let room = target - builder.measure.bytes
        guard room >= 0 else {
            scene.bitmaps.trim(toBytes: 0)
            scene.media.trim(toBytes: 0)
            builder.measure.removeAll()
            return
        }
        guard room < pictures else { return }
        let share = Double(room) / Double(pictures)
        scene.bitmaps.trim(toBytes: CrashGuard.int(Double(scene.bitmaps.bytes) * share, in: 0...scene.bitmaps.bytes))
        scene.media.trim(toBytes: CrashGuard.int(Double(scene.media.bytes) * share, in: 0...scene.media.bytes))
    }

    /// The host hid the transcript (a parked tab, an unselected conversation): drops every bitmap,
    /// picture and measurement and every row drawn only ahead of need. Work a row on screen waits
    /// for still reaches it but is not kept, so ``memoryBytes`` stays 0 until the next commit
    /// measures again or the next miss draws. The budget stays as it is.
    public func releaseHidden() {
        scene.bitmaps.releaseHidden()
        scene.media.releaseHidden()
        builder.measure.removeAll()
    }
}
