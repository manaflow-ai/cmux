public import AppKit
public import SwiftUI

/// One-pixel border derived from the terminal chrome background.
public struct WindowChromeBorder: View {
    private let orientation: WindowChromeBorderOrientation
    private let ignoresSafeAreaValue: Bool
    private let separatorColor: NSColor

    /// Creates a chrome border from an already-resolved chrome background.
    ///
    /// - Parameters:
    ///   - orientation: The axis along which the one-pixel border extends.
    ///   - ignoresSafeArea: Whether the border extends through safe-area insets.
    ///   - backgroundColor: The concrete background resolved by the window appearance snapshot.
    public init(
        orientation: WindowChromeBorderOrientation,
        ignoresSafeArea: Bool = true,
        backgroundColor: NSColor
    ) {
        self.orientation = orientation
        self.ignoresSafeAreaValue = ignoresSafeArea
        self.separatorColor = WindowChromeColorResolver().separatorColor(
            forChromeBackground: backgroundColor
        )
    }

    /// Rendered border body.
    public var body: some View {
        if ignoresSafeAreaValue {
            border.ignoresSafeArea()
        } else {
            border
        }
    }

    @ViewBuilder
    private var border: some View {
        borderShape
    }

    private var borderShape: some View {
        Rectangle()
            .fill(Color(nsColor: separatorColor))
            .frame(
                maxWidth: orientation == .horizontal ? .infinity : nil,
                maxHeight: orientation == .vertical ? .infinity : nil
            )
            .frame(
                width: orientation == .vertical ? 1 : nil,
                height: orientation == .horizontal ? 1 : nil
            )
    }

}
