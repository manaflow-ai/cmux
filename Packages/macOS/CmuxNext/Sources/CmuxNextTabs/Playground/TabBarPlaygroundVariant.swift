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
