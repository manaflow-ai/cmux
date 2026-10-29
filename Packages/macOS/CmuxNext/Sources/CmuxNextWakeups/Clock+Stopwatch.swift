extension Clock where Duration == Swift.Duration {
    /// The time since now on this clock, read at each call. Called on an `any Clock<Duration>`, it opens
    /// the existential so its instants can be compared.
    func stopwatch() -> @Sendable () -> Swift.Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}
