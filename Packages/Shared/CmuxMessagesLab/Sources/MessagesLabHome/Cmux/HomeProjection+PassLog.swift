import QuartzCore

extension HomeProjection {
    /// Adds the time since `mark` to `step` in ``passLog`` (when on) and moves `mark` to now.
    func passStep(_ step: String, _ mark: inout CFTimeInterval) {
        guard passLog != nil else { return }
        let now = CACurrentMediaTime()
        passLog?[step, default: 0] += (now - mark) * 1000
        mark = now
    }
}
