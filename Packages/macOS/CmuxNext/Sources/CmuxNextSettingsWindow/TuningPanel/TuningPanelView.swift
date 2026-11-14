import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// One surface's tunables on live controls: a slider, an exact field and a stepper per number, a menu per choice,
/// with Reset (one value or all) and Copy Values (every value as Swift constants). Edits go to the shared tunable
/// store, so the surface redraws as a slider moves, and persist for this build.
struct TuningPanelView: View {
    let model: DebugSettingsModel
    let title: String
    let export: TuningPanelExport
    @State private var notice: String?

    var body: some View {
        content(theme: SettingsTheme.shared.tokens)
    }

    /// The panel; `theme` is read in `body` only so a theme change redraws it.
    private func content(theme _: some Any) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.space3) {
                Button(TuningPanelStrings.copyValues) { copy() }
                    .buttonStyle(SettingsButtonStyle())
                    .accessibilityIdentifier("cmux.tuningPanel.copyValues")
                Button(DebugSettingsStrings.resetAll) {
                    // Only this panel's values: the store's resetAll would reset every tunable in the app.
                    model.store.reset(model.descriptors.map(\.key))
                    notice = nil
                }
                .buttonStyle(SettingsButtonStyle(destructive: true))
                .disabled(model.changedCount == 0)
                .accessibilityIdentifier("cmux.tuningPanel.resetAll")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space5)
            .padding(.top, Metrics.titlebarHeight)
            .padding(.bottom, Metrics.space3)
            Text(notice ?? TuningPanelStrings.hint)
                .font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                .padding(.horizontal, Metrics.space5)
                .padding(.bottom, Metrics.space3)
            Rectangle().fill(SettingsStyle.separator).frame(height: Metrics.dividerThickness)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.descriptors) { descriptor in
                        TuningPanelRow(model: model, descriptor: descriptor)
                    }
                }
                .padding(.vertical, Metrics.space2)
                .thinScrollers()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
    }

    private func copy() {
        let rows = model.descriptors.map { ($0, model.value($0), $0.defaultValue) }
        let text = export.swiftConstants(title: title, rows: rows)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = TuningPanelStrings.copied(rows.count)
    }
}

/// One tunable: its label (with a dot when tuned), the control and a Reset that shows only when tuned.
private struct TuningPanelRow: View {
    let model: DebugSettingsModel
    let descriptor: TunableDescriptor

    var body: some View {
        let changed = model.isChanged(descriptor)
        HStack(spacing: Metrics.space3) {
            Circle().fill(SettingsStyle.text).frame(width: Metrics.space2, height: Metrics.space2).opacity(changed ? 1 : 0)
            Text(descriptor.label)
                .font(changed ? SettingsStyle.emphasized : SettingsStyle.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedHelp(descriptor.help)
            control
            Button { model.reset(descriptor) } label: { Icon(.actionUndo, size: 12) }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsStyle.secondary)
                .themedHelp(DebugSettingsStrings.defaultIs(DebugSettingsStrings.display(descriptor.defaultValue, kind: descriptor.kind)))
                .accessibilityLabel(SettingsWindowStrings.reset)
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.tuningPanel.row.\(descriptor.key)")
    }

    @ViewBuilder private var control: some View {
        if case let .number(range, step, unit) = descriptor.kind {
            let value = Binding(get: { model.value(descriptor).number ?? range.lowerBound }, set: { model.set(descriptor, .number($0)) })
            HStack(spacing: Metrics.space2) {
                DebugNumberField(value: value, range: range, step: step, unit: unit)
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
        } else {
            DebugTunableControl(model: model, descriptor: descriptor)
        }
    }
}
