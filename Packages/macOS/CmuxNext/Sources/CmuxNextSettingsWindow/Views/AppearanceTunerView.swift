public import CmuxNextDesign
public import SwiftUI

/// Compact slider controls shared by the Appearance Studio and its one-slider
/// peek panel. State remains local to the view while the host owns the live
/// ThemeScope mutation.
public struct AppearanceTunerView: View {
    private let axis: AppearanceTuningAxis?
    private let showsPeek: Bool
    private let onChange: (AppearanceTuning) -> Void
    private let onPeek: (AppearanceTuningAxis) -> Void
    private let onDone: () -> Void
    @State private var tuning: AppearanceTuning

    public init(axis: AppearanceTuningAxis? = nil, initial: AppearanceTuning = .identity,
                showsPeek: Bool = true, onChange: @escaping (AppearanceTuning) -> Void = { _ in },
                onPeek: @escaping (AppearanceTuningAxis) -> Void = { _ in },
                onDone: @escaping () -> Void = {}) {
        self.axis = axis
        self.showsPeek = showsPeek
        self.onChange = onChange
        self.onPeek = onPeek
        self.onDone = onDone
        _tuning = State(initialValue: initial)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(SettingsWindowStrings.tunerTitle).font(SettingsStyle.header)
                Spacer(minLength: 0)
                if axis != nil { Button(SettingsWindowStrings.tunerDone, action: onDone).buttonStyle(SettingsButtonStyle()) }
            }
            if axis == nil { Text(SettingsWindowStrings.tunerHint).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary) }
            ForEach(axis.map { [$0] } ?? AppearanceTuningAxis.allCases) { item in
                row(item)
            }
        }
    }

    private func row(_ axis: AppearanceTuningAxis) -> some View {
        HStack(spacing: Metrics.space2) {
            Text(title(for: axis)).font(SettingsStyle.body).frame(width: 112, alignment: .leading)
            Slider(value: Binding(get: { tuning.value(for: axis) }, set: {
                tuning = tuning.setting(axis, to: $0)
                onChange(tuning)
            }), in: range(for: axis))
            if showsPeek {
                Button { onPeek(axis) } label: { Image(systemName: "eye") }
                    .buttonStyle(.plain)
                    .help(SettingsWindowStrings.tunerPeek)
                    .accessibilityLabel(SettingsWindowStrings.tunerPeek)
            }
        }
    }

    private func title(for axis: AppearanceTuningAxis) -> String {
        switch axis {
        case .glassTransparency: SettingsWindowStrings.tunerTransparency
        case .hue: SettingsWindowStrings.tunerHue
        case .saturation: SettingsWindowStrings.tunerSaturation
        }
    }

    private func range(for axis: AppearanceTuningAxis) -> ClosedRange<Double> {
        switch axis {
        case .glassTransparency, .hue: 0...1
        case .saturation: 0...2
        }
    }
}
