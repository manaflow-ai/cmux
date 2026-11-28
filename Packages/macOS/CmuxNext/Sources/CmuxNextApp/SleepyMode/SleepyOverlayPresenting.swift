/// Shows and hides Sleepy Mode's scene. ``SleepyOverlayWindows`` covers every
/// screen; tests pass a fake that records the calls.
@MainActor
protocol SleepyOverlayPresenting: AnyObject {
    /// True while the scene shows.
    var isShowing: Bool { get }
    /// Covers the screens with the scene. `wake` runs on any key or click on it.
    func show(wake: @escaping @MainActor () -> Void)
    /// Removes the scene from every screen.
    func hide()
}
