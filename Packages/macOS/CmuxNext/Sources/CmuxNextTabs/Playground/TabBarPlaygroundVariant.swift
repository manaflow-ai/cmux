import AppKit

/// DEV and NIGHTLY (the Debug menu): one design in the tab bar playground (``TabBarPlaygroundView``): its caption and the
/// live view it shows, built for a tab count. The shipped design is marked, so a gallery reads which
/// one the app has now.
struct TabBarPlaygroundVariant {
    /// The caption above the variant's row.
    let name: String
    /// The app ships this one today.
    var isShipped = false
    /// Builds the row's content for `tabCount` tabs (the real tab strip, with live hover and clicks).
    let make: @MainActor (_ tabCount: Int) -> NSView
}

/// A playground row taller than the tab strip. ``TabBarPlaygroundView`` gives each row this height (any other
/// view the strip's), so a new row sizes itself by conforming instead of by a type check the page must learn.
/// The Folder Corners rows were missing from that check and drew cut down to the strip (cmux#41989 F1).
protocol TabBarPlaygroundRow: NSView {
    static var preferredHeight: CGFloat { get }
}
