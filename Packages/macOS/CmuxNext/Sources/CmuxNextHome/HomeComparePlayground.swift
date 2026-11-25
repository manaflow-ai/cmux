#if DEBUG
import MessagesLabHome

/// DEBUG ONLY: Debug > Before/After Table Playground, the app's door to MessagesLab's
/// ``HomeCompareTablePlayground`` (seven live ways to show a Before|After × Light|Dark table of pictures).
@MainActor
public struct HomeComparePlayground {
    public init() {}

    /// Shows the playground on `variant` (1...7), picture set `row` (0 Light, 1 Dark) and the window's look
    /// (`dark`); nil keeps what it shows.
    public func show(variant: Int?, row: Int?, dark: Bool?) {
        HomeCompareTablePlayground.show(variant: variant, row: row, dark: dark)
    }
}
#endif
