public import CoreGraphics

/// Shared horizontal geometry for the terminal composer and its keyboard dock.
///
/// Keeping the leading margin in the support package prevents the UIKit keyboard
/// control and the SwiftUI attachment controls from drifting apart as either
/// surface evolves.
public struct MobileComposerLayout: Sendable {
    public static let standard = Self()

    /// Leading and trailing margin used by the terminal composer chrome.
    public let horizontalInset: CGFloat

    public init(horizontalInset: CGFloat = 12) {
        self.horizontalInset = horizontalInset
    }
}
