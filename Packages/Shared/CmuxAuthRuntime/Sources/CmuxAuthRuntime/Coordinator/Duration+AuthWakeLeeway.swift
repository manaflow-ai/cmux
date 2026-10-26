extension Duration {
    /// The `tolerance:` an auth deadline or retry wait of this length passes to
    /// its clock, so the kernel can fire it together with other wakes.
    ///
    /// 10% of the wait, at least 8 ms and at most 1 s: Chromium's default
    /// leeway (`kDefaultLeeway`, base/task/task_features.cc) as the floor, and
    /// the 10%/1 s flexible-delay slack of p14-energy.md section B. No auth
    /// deadline or retry needs to fire more exactly than that.
    var authWakeLeeway: Duration {
        max(Duration.milliseconds(8), min(self / 10, Duration.seconds(1)))
    }
}
