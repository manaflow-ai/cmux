/// Keys typed into a page surface before its document can take them (spec
/// app-screens.md section 3, R59): one surface's printable text, in order,
/// bounded to ``maxCharacters`` and ``maxAge``. Pure; the key router owns
/// one and drops it on a chord or a focus move.
struct TypeAheadQueue: Equatable {
    static let maxCharacters = 256
    static let maxAge: Duration = .seconds(2)

    private(set) var surface: String?
    private(set) var text = ""
    private var started: ContinuousClock.Instant?

    /// Whether text waits for `surface`.
    func pending(for surface: String) -> Bool {
        self.surface == surface && !text.isEmpty
    }

    /// Appends `characters` for `surface`; text for another surface, or text
    /// older than ``maxAge``, is dropped first. Characters past
    /// ``maxCharacters`` are dropped.
    mutating func append(_ characters: String, surface: String, now: ContinuousClock.Instant) {
        if self.surface != surface || isExpired(now) { reset(surface: surface, now: now) }
        text += characters.prefix(max(0, Self.maxCharacters - text.count))
    }

    /// Delete while the page loads removes the last queued character.
    mutating func deleteBackward(surface: String) {
        guard self.surface == surface, !text.isEmpty else { return }
        text.removeLast()
    }

    /// The queued text for `surface`, once; nil when none waits or it is
    /// older than ``maxAge`` (then it is dropped).
    mutating func take(surface: String, now: ContinuousClock.Instant) -> String? {
        guard self.surface == surface, !text.isEmpty else { return nil }
        let expired = isExpired(now)
        let taken = text
        drop()
        return expired ? nil : taken
    }

    mutating func drop() {
        surface = nil
        text = ""
        started = nil
    }

    private func isExpired(_ now: ContinuousClock.Instant) -> Bool {
        started.map { now - $0 > Self.maxAge } ?? false
    }

    private mutating func reset(surface: String, now: ContinuousClock.Instant) {
        self.surface = surface
        text = ""
        started = now
    }
}
