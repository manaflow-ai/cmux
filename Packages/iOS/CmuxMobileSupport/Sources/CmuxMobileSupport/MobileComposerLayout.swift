public import CoreGraphics

/// Shared horizontal geometry for the terminal composer and its keyboard dock.
///
/// Keeping the leading margin in the support package prevents the UIKit keyboard
/// control and the SwiftUI attachment controls from drifting apart as either
/// surface evolves.
public enum MobileComposerLayout {
    /// Leading and trailing margin used by the terminal composer chrome.
    public static let horizontalInset: CGFloat = 12
}
