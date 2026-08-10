public import CoreGraphics
internal import Foundation
#if canImport(UIKit)
internal import UIKit
#elseif canImport(AppKit)
internal import AppKit
#endif

/// Pure sizing logic for the two fixed-width diff gutters.
public struct DiffGutterLayout: Sendable, Equatable {
    /// Maximum line number represented by the gutter.
    public let maximumLineNumber: Int

    /// Creates a gutter layout.
    /// - Parameter maximumLineNumber: Largest old or new line number.
    public init(maximumLineNumber: Int) {
        self.maximumLineNumber = max(0, maximumLineNumber)
    }

    /// Number of monospaced digits needed by each gutter.
    public var digitCount: Int {
        max(1, String(maximumLineNumber).count)
    }

    /// Computes a fixed gutter width from a measured monospaced-digit advance.
    /// - Parameter monospacedDigitAdvance: Measured width of one digit.
    /// - Returns: Width including four points of horizontal breathing room.
    public func width(monospacedDigitAdvance: CGFloat) -> CGFloat {
        CGFloat(digitCount) * max(0, monospacedDigitAdvance) + 4
    }

    func measuredWidth(fontSize: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let advance = ("8" as NSString).size(withAttributes: [.font: font]).width
        #elseif canImport(AppKit)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let advance = ("8" as NSString).size(withAttributes: [.font: font]).width
        #else
        let advance = fontSize * 0.62
        #endif
        return width(monospacedDigitAdvance: advance)
    }
}
