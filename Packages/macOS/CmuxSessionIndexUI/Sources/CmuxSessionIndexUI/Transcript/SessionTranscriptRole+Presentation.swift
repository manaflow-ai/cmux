public import SwiftUI

import CmuxSessionIndex

/// SwiftUI presentation for a transcript role's color and font.
///
/// These accessors carry no localization, so they live in the package alongside the
/// views that render them. The role's speaker *label* stays app-side (it depends on
/// `String(localized:)`, which must resolve against the app bundle) and is threaded in
/// through ``SessionTranscriptPreviewStrings/roleLabel``.
extension SessionTranscriptRole {
    /// The accent color for a role's label and rule.
    public var foregroundColor: Color {
        switch self {
        case .user: return .accentColor
        case .assistant: return .green
        case .system: return .secondary
        case .tool: return .orange
        case .event: return .secondary
        }
    }

    /// The tint behind a role's turn text.
    public var backgroundColor: Color {
        switch self {
        case .user: return Color.accentColor.opacity(0.035)
        case .assistant: return Color.green.opacity(0.035)
        case .system: return Color.primary.opacity(0.025)
        case .tool: return Color.orange.opacity(0.035)
        case .event: return Color.primary.opacity(0.02)
        }
    }

    /// The body font for a role's turn text (monospaced for tool/system).
    public var bodyFont: Font {
        switch self {
        case .tool, .system:
            return .system(size: 11, design: .monospaced)
        case .user, .assistant, .event:
            return .system(size: 12)
        }
    }
}
