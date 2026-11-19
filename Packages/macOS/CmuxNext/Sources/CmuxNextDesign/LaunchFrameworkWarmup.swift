import CoreText
import Metal

/// Warms framework state needed by the first window while launch reads are in flight.
public final class LaunchFrameworkWarmup {
    private init() {}

    /// Starts the one-shot launch warmup without making the first frame wait for it.
    public static func start() {
        Task.detached(priority: .utility) {
            _ = MTLCreateSystemDefaultDevice()
            _ = CTFontCreateUIFontForLanguage(.system, 13, nil)
        }
    }
}
