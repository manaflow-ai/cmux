import AppKit
public import SwiftUI

/// A `ViewModifier` that makes the enclosing `NSScrollView` fully transparent, hiding the
/// SwiftUI scroll content background and clearing the AppKit scroll-view layer chain.
public struct ClearScrollBackground: ViewModifier {
    /// Creates the clear-scroll-background modifier.
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(ScrollBackgroundClearer())
        } else {
            content
                .background(ScrollBackgroundClearer())
        }
    }
}
