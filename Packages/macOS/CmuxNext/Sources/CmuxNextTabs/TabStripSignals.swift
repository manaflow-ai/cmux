/// Tab strip moments the App reacts to beyond the strip's own model: the
/// pointer entering the "+" button predicts a new tab (the App's Chromium
/// warm start, ChromiumWarmup). Process-wide, main thread.
public final class TabStripSignals {
    public static let shared = TabStripSignals()

    /// The pointer entered a strip's "+" button.
    public var onNewTabButtonHover: (() -> Void)?
}
