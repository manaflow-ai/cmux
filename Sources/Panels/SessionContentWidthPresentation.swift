import CmuxSettings
import CoreGraphics

/// Resolved session-width values shared by SwiftUI and direct AppKit terminal hosts.
struct SessionContentWidthPresentation: Equatable, Sendable {
    static let disabled = SessionContentWidthPresentation(
        storedMaximumWidth: SessionContentWidthSettings.noMaximumWidth,
        storedAlignment: SessionContentAlignment.center.rawValue
    )

    let maximumWidth: CGFloat?
    let alignment: SessionContentAlignment

    init(storedMaximumWidth: Double, storedAlignment: String) {
        maximumWidth = SessionContentWidthSettings()
            .configuredMaximumWidth(from: storedMaximumWidth)
            .map { CGFloat($0) }
        alignment = SessionContentAlignment(rawValue: storedAlignment) ?? .center
    }

    /// Returns the content rectangle inside full-pane bounds.
    func contentFrame(in bounds: CGRect) -> CGRect {
        guard let maximumWidth, bounds.width > maximumWidth else { return bounds }

        let x: CGFloat
        switch alignment {
        case .left:
            x = bounds.minX
        case .center:
            x = bounds.minX + (bounds.width - maximumWidth) / 2
        case .right:
            x = bounds.maxX - maximumWidth
        }
        return CGRect(x: x, y: bounds.minY, width: maximumWidth, height: bounds.height)
    }
}
