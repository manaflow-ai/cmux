/// A sidebar card the Toast Playground can show for real in the window the person works in (the one-time
/// GitHub star ask): the playground lists one Show button per card. The app supplies them, since the cards
/// live above this package.
///
/// ```swift
/// CmuxToastPlaygroundCard(title: "GitHub star ask") { updater.debugStarPrompt(press: nil) }
/// ```
public struct CmuxToastPlaygroundCard {
    /// The button's name in the playground.
    public var title: String
    /// Shows the card in the active window's sidebar.
    public var show: @MainActor () -> Void

    /// - Parameters:
    ///   - title: The button's name in the playground.
    ///   - show: Shows the card in the active window's sidebar.
    public init(title: String, show: @escaping @MainActor () -> Void) {
        self.title = title
        self.show = show
    }
}
