import CmuxSettings
import SwiftUI

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

    var swiftUIAlignment: Alignment {
        switch alignment {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }
}

/// Applies the shared width cap and horizontal placement to session surfaces.
struct SessionContentWidthModifier: ViewModifier {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedMaximumWidth = SessionContentWidthSettings.noMaximumWidth

    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedAlignment = SessionContentAlignment.center.rawValue

    let fillsHeight: Bool

    func body(content: Content) -> some View {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: storedMaximumWidth,
            storedAlignment: storedAlignment
        )
        content
            .frame(
                maxWidth: presentation.maximumWidth ?? .infinity,
                maxHeight: fillsHeight ? .infinity : nil
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsHeight ? .infinity : nil,
                alignment: presentation.swiftUIAlignment
            )
    }
}

extension View {
    /// Caps terminal and agent-session content while keeping the pane full-size.
    func sessionContentWidth(fillsHeight: Bool = true) -> some View {
        modifier(SessionContentWidthModifier(fillsHeight: fillsHeight))
    }
}
