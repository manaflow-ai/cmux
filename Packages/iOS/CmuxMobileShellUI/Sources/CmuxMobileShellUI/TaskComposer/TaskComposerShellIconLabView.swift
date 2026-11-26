#if os(iOS) && DEBUG
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Debug-only Settings surface for comparing small Shell badge adjustments in
/// the exact task-composer card that ships in the app.
struct TaskComposerShellIconLabView: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string(
                        "mobile.settings.shellIconLab.selected",
                        defaultValue: "Selected Shell Card"
                    ))
                    .font(.headline)

                    TaskComposerTemplateOption(
                        template: shellTemplate,
                        isSelected: true,
                        isDisabled: false,
                        shellIconVariant: displaySettings.taskComposerShellIconVariant,
                        action: {}
                    )
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("MobileShellIconLabSelectedPreview")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string(
                        "mobile.settings.shellIconLab.variants",
                        defaultValue: "Variants"
                    ))
                    .font(.headline)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(TaskComposerShellIconVariant.allCases) { variant in
                            variantButton(
                                variant,
                                selection: $displaySettings.taskComposerShellIconVariant
                            )
                        }
                    }
                }

                Text(L10n.string(
                    "mobile.settings.shellIconLab.footer",
                    defaultValue: "The first value is icon size. Stroke weights are 400 regular, 500 medium, and 600 semibold. α changes contrast; ○ changes circle size. Choose a variant, then reopen New Task."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.string(
            "mobile.settings.shellIconLab",
            defaultValue: "Shell Icon Lab"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileShellIconLab")
    }

    private func variantButton(
        _ variant: TaskComposerShellIconVariant,
        selection: Binding<TaskComposerShellIconVariant>
    ) -> some View {
        let isSelected = selection.wrappedValue == variant
        return Button {
            selection.wrappedValue = variant
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16 * variant.circleOpacityScale))
                        .frame(
                            width: 40 * variant.circleScale,
                            height: 40 * variant.circleScale
                        )
                        .frame(width: 40, height: 40)
                    TaskTemplateIcon(value: "terminal", size: 22, shellVariant: variant)
                        .frame(width: 40, height: 40)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 3, y: -2)
                            .accessibilityHidden(true)
                    }
                }

                Text(verbatim: "\(variant.code) · \(variant.title)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
                Text(verbatim: variant.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(variant.code), \(variant.title), \(variant.detail)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileShellIconVariant-\(variant.code)")
    }

    private var shellTemplate: MobileTaskTemplate {
        MobileTaskTemplate(
            name: L10n.string(
                "mobile.taskComposer.template.seed.shell",
                defaultValue: "Shell"
            ),
            icon: "terminal",
            command: ""
        )
    }
}
#endif
