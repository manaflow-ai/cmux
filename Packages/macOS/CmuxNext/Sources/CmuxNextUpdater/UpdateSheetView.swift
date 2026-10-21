import Combine
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
                    .modifier(IndeterminateSymbolEffect(isActive: content.progress == .indeterminate))
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
                let cancel = content.buttons.dropLast().firstIndex(where: \.dismisses)
                ForEach(Array(content.buttons.enumerated()), id: \.element) { index, button in
                    let isDefault = index == content.buttons.count - 1
                    // The last button is Return's; the first other one that closes the sheet, Escape's.
                    CmuxDialogActionButton(button.title, hint: isDefault ? .return : (index == cancel ? .escape : nil)) { press(button) }
                        .glassButtonStyle()
                        .font(Font(isDefault ? Typography.bodyEmphasized : Typography.body))
                }
            }
        }
    }

    private func press(_ button: UpdateSheetButton) {
        source.perform(button)
        if button.dismisses { dismiss() }
    }
}

/// The indeterminate-progress symbol effect: rotate on macOS 15 and newer,
/// pulse on macOS 14 (no rotate effect there). Still while loops are off
/// (Reduce Motion or `ui.animationSpeed` off; cx-sya4n: nothing loops). The
/// environment's Reduce Motion and `Motion.reduceMotionDidChange` re-run the
/// body when either changes while the sheet shows.
private struct IndeterminateSymbolEffect: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @State private var overrideChanges = 0

    func body(content: Content) -> some View {
        // Read so a change of either re-runs this body; `Motion` reads the live values.
        _ = (systemReducesMotion, overrideChanges)
        let runs = isActive && Motion.indicators.animatesLoops
        return Group {
            if #available(macOS 15, *) {
                // motion: allow the effect runs only while Motion.indicators.animatesLoops (`runs`)
                content.symbolEffect(.rotate, isActive: runs)
            } else {
                // motion: allow the effect runs only while Motion.indicators.animatesLoops (`runs`)
                content.symbolEffect(.pulse, isActive: runs)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Motion.reduceMotionDidChange)) { _ in overrideChanges += 1 }
    }
}
