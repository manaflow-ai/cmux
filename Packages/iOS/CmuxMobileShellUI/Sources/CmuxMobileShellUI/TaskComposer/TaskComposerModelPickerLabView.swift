#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

/// Debug-only Settings surface for selecting the New Task model-picker UX.
struct TaskComposerModelPickerLabView: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return List {
            Section {
                ForEach(TaskComposerLayoutStyle.allCases) { style in
                    Button {
                        displaySettings.taskComposerLayoutStyle = style
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: style.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(verbatim: style.detail)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }

                            Spacer(minLength: 8)

                            if displaySettings.taskComposerLayoutStyle == style {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: style.title))
                    .accessibilityHint(Text(verbatim: style.detail))
                    .accessibilityAddTraits(
                        displaySettings.taskComposerLayoutStyle == style ? .isSelected : []
                    )
                    .accessibilityIdentifier("MobileTaskComposerLayout-\(style.rawValue)")
                }
            } header: {
                Text(L10n.string(
                    "mobile.settings.modelPickerLab.layout",
                    defaultValue: "Layout"
                ))
            }

            Section {
                ForEach(TaskComposerModelPickerVariant.allCases) { variant in
                    Button {
                        displaySettings.taskComposerModelPickerVariant = variant
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "\(variant.code) · \(variant.title)")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(verbatim: variant.detail)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }

                            Spacer(minLength: 8)

                            if displaySettings.taskComposerModelPickerVariant == variant {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(variant.code), \(variant.title)"))
                    .accessibilityHint(Text(verbatim: variant.detail))
                    .accessibilityAddTraits(
                        displaySettings.taskComposerModelPickerVariant == variant ? .isSelected : []
                    )
                    .accessibilityIdentifier("MobileModelPickerVariant-\(variant.code)")
                }
            } footer: {
                Text(L10n.string(
                    "mobile.settings.modelPickerLab.footer",
                    defaultValue: "Choose a layout and model variant, then reopen New Task."
                ))
            }
        }
        .navigationTitle(L10n.string(
            "mobile.settings.modelPickerLab",
            defaultValue: "New Task Model Lab"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileModelPickerLab")
    }
}
#endif
