#if os(iOS)
import SwiftUI

/// Variants used by the debug-only Shell icon lab.
///
/// Keep each option close to the current treatment so one visual variable can
/// be judged at a time. The chosen values are applied at render time and never
/// mutate the user's persisted task templates. Release builds collapse every
/// render parameter to ``current``.
enum TaskComposerShellIconVariant: String, CaseIterable, Identifiable, Sendable {
    case current
    case regular
    case medium
    case semibold92
    case semibold86
    case medium92
    case medium86
    case regular92
    case regular86
    case regular78
    case soft86
    case inset90

    var id: String { rawValue }

    var code: String {
        switch self {
        case .current: "A"
        case .regular: "B"
        case .medium: "C"
        case .semibold92: "D"
        case .semibold86: "E"
        case .medium92: "F"
        case .medium86: "G"
        case .regular92: "H"
        case .regular86: "I"
        case .regular78: "J"
        case .soft86: "K"
        case .inset90: "L"
        }
    }

    var title: String {
        switch self {
        case .current: "100% · 600"
        case .regular: "100% · 400"
        case .medium: "100% · 500"
        case .semibold92: "92% · 600"
        case .semibold86: "86% · 600"
        case .medium92: "92% · 500"
        case .medium86: "86% · 500"
        case .regular92: "92% · 400"
        case .regular86: "86% · 400"
        case .regular78: "78% · 400"
        case .soft86: "86% · 500"
        case .inset90: "90% · 500"
        }
    }

    var detail: String {
        switch self {
        case .current, .regular, .medium: "22 pt"
        case .semibold92, .medium92, .regular92: "20 pt"
        case .semibold86, .medium86, .regular86: "19 pt"
        case .regular78: "17 pt"
        case .soft86: "19 pt · α82"
        case .inset90: "20 pt · ○90"
        }
    }

    var glyphScale: CGFloat {
        switch renderedVariant {
        case .current, .regular, .medium: 1
        case .semibold92, .medium92, .regular92: 0.92
        case .semibold86, .medium86, .regular86, .soft86: 0.86
        case .regular78: 0.78
        case .inset90: 0.90
        }
    }

    var glyphWeight: Font.Weight {
        switch renderedVariant {
        case .current, .semibold92, .semibold86:
            .semibold
        case .medium, .medium92, .medium86, .soft86, .inset90:
            .medium
        case .regular, .regular92, .regular86, .regular78:
            .regular
        }
    }

    var glyphOpacity: Double {
        renderedVariant == .soft86 ? 0.82 : 1
    }

    var circleScale: CGFloat {
        renderedVariant == .inset90 ? 0.90 : 1
    }

    var circleOpacityScale: Double {
        renderedVariant == .soft86 ? 0.80 : 1
    }

    private var renderedVariant: TaskComposerShellIconVariant {
        #if DEBUG
        self
        #else
        .current
        #endif
    }
}
#endif
