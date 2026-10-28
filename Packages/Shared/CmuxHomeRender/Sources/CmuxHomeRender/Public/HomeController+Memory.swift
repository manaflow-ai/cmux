/// The controller's caches for the host's memory policy, with no platform type: the Mac registers
/// them with its memory coordinator (CmuxNextHome's `HomeRenderMemoryConsumer`); iOS sizes them
/// once with `memoryBudget`.
///
/// The budget covers the row bitmaps and decoded pictures. The rows on screen always keep theirs
/// (their layers hold them, so dropping them would free nothing and draw or load them again on the
/// next commit), and a pooled row holds no image, so ``memoryBytes`` is what the caches hold.
/// Text measurements are the transcript's working set: every commit reads them, and the model's
/// rows share their layouts, so they are reported (``measurementBytes``) and never dropped.
extension HomeController {
    /// The bytes the row bitmap and picture caches hold now (pixel bytes). Read from counters,
    /// never a walk.
    public var memoryBytes: Int {
        scene.bitmaps.bytes + scene.media.bytes
    }

    /// The entries the row bitmap and picture caches hold now.
    public var memoryEntryCount: Int {
        scene.bitmaps.count + scene.media.count
    }

    /// The estimated bytes of the text measurements: they follow the loaded transcript and are
    /// never dropped (the next commit would measure the whole transcript again on the main actor).
    public var measurementBytes: Int {
        builder.measure.bytes
    }

    /// The text measurements kept.
    public var measurementCount: Int {
        builder.measure.count
    }

    /// Frees now down to `fraction` of ``memoryBytes``: the oldest bitmaps and the least recently
    /// used pictures first, in the same share from each. What the rows on screen show stays, so
    /// `0` leaves exactly that. The budget stays as it is.
    ///
    /// - Parameter fraction: The share of what the caches hold now to keep, 0...1 (NaN keeps all).
    public func trim(toFraction fraction: Double) {
        guard !fraction.isNaN else { return }
        let share = min(max(fraction, 0), 1)
        let bitmaps = scene.bitmaps.bytes
        let pictures = scene.media.bytes
        scene.bitmaps.trim(toBytes: CrashGuard.int(Double(bitmaps) * share, in: 0...bitmaps))
        scene.media.trim(toBytes: CrashGuard.int(Double(pictures) * share, in: 0...pictures))
    }

    /// The host hid (a parked tab, an unselected conversation) or showed the transcript.
    ///
    /// Hiding returns every row to the pool with no image, cancels every draw and load, and empties
    /// the bitmap and picture caches, so ``memoryBytes`` is 0. While hidden, updates change the
    /// model and layout only: no row shows, draws or loads. Showing lays out once to the final
    /// state, and the rows on screen draw again off the main actor. The budget stays as it is.
    ///
    /// - Parameter hidden: Whether the transcript is hidden.
    public func setHidden(_ hidden: Bool) {
        scene.setHidden(hidden)
    }

    /// Whether the host hid the transcript (``setHidden(_:)``).
    public var isHidden: Bool {
        scene.isHidden
    }
}
