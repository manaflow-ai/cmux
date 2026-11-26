/// Plays the notification sounds cmux plays itself: every sound but a banner's `"default"`, which
/// the banner carries so Focus and the per-app sound switch apply. ``NotificationSoundGate`` holds
/// one; tests pass a recorder.
@MainActor
public protocol NotificationSoundPlaying: AnyObject {
    /// Plays `name` at `volume`.
    ///
    /// - Parameters:
    ///   - name: A sound name (``NotificationSoundLibrary``), an absolute or `~/` path, `"default"`
    ///     or `"none"` (nothing plays).
    ///   - volume: 0 to 1.
    ///   - banner: A banner shows with it: `"default"` then rides the banner and plays nothing here;
    ///     without one, the system alert sound stands in.
    func play(_ name: String, volume: Double, banner: Bool)
}
