import CmuxNextDesign
import SwiftUI

/// The compact update sheet body. Hosted in a glass panel by
/// ``UpdateSheetController``; gray chrome only (no accent color).
struct UpdateSheetView: View {
    let source: any UpdateSheetSource
    let dismiss: () -> Void

    var body: some View {
        if let content = source.content {
            layout(content)
                .padding(Metrics.space6)
                .frame(width: Metrics.paletteWidth / 2, alignment: .leading)
                .tint(Color(nsColor: Palette.focusRing))
        }
    }

    private func layout(_ content: UpdateSheetContent) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space5) {
            HStack(alignment: .top, spacing: Metrics.space5) {
                Image(systemName: content.symbol)
                    .font(.system(size: Metrics.iconSize * 1.6, weight: .regular))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .frame(width: Metrics.iconSize * 2)
                    .symbolEffect(.rotate, isActive: content.progress == .indeterminate)
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Text(content.title)
                        .font(Font(Typography.bodyEmphasized))
                        .foregroundStyle(Color(nsColor: Palette.textPrimary))
                    if let detail = content.detail {
                        Text(detail)
                            .font(Font(Typography.caption))
                            .foregroundStyle(Color(nsColor: Palette.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    progress(content.progress)
                }
            }
            buttons(content)
        }
    }

    @ViewBuilder
    private func progress(_ progress: UpdateSheetContent.Progress) -> some View {
        switch progress {
        case .none:
            EmptyView()
        case .indeterminate:
            ProgressView().progressViewStyle(.linear).padding(.top, Metrics.space2)
        case .fraction(let value):
            ProgressView(value: value).progressViewStyle(.linear).padding(.top, Metrics.space2)
        }
    }

    @ViewBuilder
    private func buttons(_ content: UpdateSheetContent) -> some View {
        if content.link != nil || !content.buttons.isEmpty {
            HStack(spacing: Metrics.space4) {
                if let link = content.link {
                    Button(link.title) { press(link) }
                        .buttonStyle(.plain)
                        .font(Font(Typography.caption))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .underline()
                }
                Spacer(minLength: 0)
                ForEach(Array(content.buttons.enumerated()), id: \.element) { index, button in
                    let isDefault = index == content.buttons.count - 1
                    Button(button.title) { press(button) }
                        .buttonStyle(.glass)
                        .font(Font(isDefault ? Typography.bodyEmphasized : Typography.body))
                        .keyboardShortcut(isDefault ? .defaultAction : (button.dismisses ? .cancelAction : nil))
                }
            }
        }
    }

    private func press(_ button: UpdateSheetButton) {
        source.perform(button)
        if button.dismisses { dismiss() }
    }
}
