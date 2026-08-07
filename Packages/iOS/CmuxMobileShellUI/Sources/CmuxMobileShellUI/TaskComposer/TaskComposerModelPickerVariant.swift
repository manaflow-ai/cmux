#if os(iOS)
import CmuxMobileSupport

/// Runtime-selectable model-picker treatments used by the debug CMUX Lab.
enum TaskComposerModelPickerVariant: String, CaseIterable, Identifiable, Sendable {
    case off
    case combined
    case separateRow
    case trailingChip
    case pillStrip
    case contextRow

    var id: String { rawValue }

    var code: String {
        switch self {
        case .off: "Off"
        case .combined: "A"
        case .separateRow: "B"
        case .trailingChip: "C"
        case .pillStrip: "D"
        case .contextRow: "E"
        }
    }

    var title: String {
        switch self {
        case .off:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.off.title",
                defaultValue: "Off"
            )
        case .combined:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.combined.title",
                defaultValue: "Combined Agent Menu"
            )
        case .separateRow:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.separateRow.title",
                defaultValue: "Model Row"
            )
        case .trailingChip:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.trailingChip.title",
                defaultValue: "Model Chip"
            )
        case .pillStrip:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.pillStrip.title",
                defaultValue: "Model Pills"
            )
        case .contextRow:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.contextRow.title",
                defaultValue: "Context Row"
            )
        }
    }

    var detail: String {
        switch self {
        case .off:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.off.detail",
                defaultValue: "No model selection in New Task."
            )
        case .combined:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.combined.detail",
                defaultValue: "Pick agent and model in one menu."
            )
        case .separateRow:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.separateRow.detail",
                defaultValue: "Dedicated model row under the agent."
            )
        case .trailingChip:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.trailingChip.detail",
                defaultValue: "Compact model chip on the agent row."
            )
        case .pillStrip:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.pillStrip.detail",
                defaultValue: "One-tap model pills under the agent."
            )
        case .contextRow:
            L10n.string(
                "mobile.settings.modelPickerLab.variant.contextRow.detail",
                defaultValue: "Model row beside Mac and directory."
            )
        }
    }

    var renderedVariant: TaskComposerModelPickerVariant {
        #if DEBUG
        self
        #else
        .off
        #endif
    }
}
#endif
