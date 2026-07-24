#if os(iOS)
import CmuxMobileSupport

/// Runtime-selectable New Task layouts used by the debug CMUX Lab.
enum TaskComposerLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case composer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:
            L10n.string(
                "mobile.settings.modelPickerLab.layout.classic.title",
                defaultValue: "Classic"
            )
        case .composer:
            L10n.string(
                "mobile.settings.modelPickerLab.layout.composer.title",
                defaultValue: "Composer"
            )
        }
    }

    var detail: String {
        switch self {
        case .classic:
            L10n.string(
                "mobile.settings.modelPickerLab.layout.classic.detail",
                defaultValue: "Card sheet with Start button."
            )
        case .composer:
            L10n.string(
                "mobile.settings.modelPickerLab.layout.composer.detail",
                defaultValue: "Full-screen prompt with a bottom control bar."
            )
        }
    }

    var renderedStyle: TaskComposerLayoutStyle {
        #if DEBUG
        self
        #else
        .classic
        #endif
    }
}
#endif
