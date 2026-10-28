extension Int {
    /// The bytes a cache that holds `self` bytes keeps when its host trims it to `fraction` of them:
    /// `fraction` is clamped to 0...1 and NaN keeps everything, so a bad fraction
    /// never frees more than asked or traps.
    func trimTarget(_ fraction: Double) -> Int {
        guard !fraction.isNaN else { return self }
        let held = Swift.max(self, 0)
        return CrashGuard.int(Double(held) * Swift.min(Swift.max(fraction, 0), 1), in: 0...held)
    }
}
