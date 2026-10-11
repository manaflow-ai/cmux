import CmuxNextDesign
import SwiftUI

/// A slider for quick moves plus an exact field (type any value, Return
/// applies it; the store clamps it to the range).
struct DebugNumberField: View {
    var title: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: TunableUnit
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Metrics.space4) {
            if let title {
                Text(title).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = snap($0) }),
                   in: range)
                .frame(width: Metrics.sidebarWidth * 0.8)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: Metrics.tabMinWidth * 2)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { if !editing { commit() } }
            Text(unitSuffix).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.tertiary)
                .frame(minWidth: Metrics.space6, alignment: .leading)
        }
        .onAppear { text = TunableExport.format(display(value)) }
        .onChange(of: value) { if !editing { text = TunableExport.format(display(value)) } }
    }

    /// Fractions show as percentages; everything else as stored.
    private func display(_ number: Double) -> Double { unit == .fraction ? (number * 1000).rounded() / 10 : number }

    private var unitSuffix: String {
        switch unit {
        case .points: "pt"
        case .seconds: "s"
        case .fraction: "%"
        case .multiplier: "×"
        case .pointsPerSecond: "pt/s"
        case .count: ""
        }
    }

    private func snap(_ number: Double) -> Double {
        guard step > 0 else { return number }
        let steps = ((number - range.lowerBound) / step).rounded()
        return ((range.lowerBound + steps * step) * 10_000).rounded() / 10_000
    }

    private func commit() {
        // Leaving the field without typing must not round the stored value.
        guard text != TunableExport.format(display(value)) else { return }
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let typed = Double(cleaned) else {
            text = TunableExport.format(display(value))
            return
        }
        value = unit == .fraction ? typed / 100 : typed
    }
}

/// A menu of theme color roles, each with its swatch in the window's theme.
struct DebugColorPicker: View {
    @Binding var selection: TunableColor

    var body: some View {
        let tokens = SettingsTheme.shared.tokens
        Menu {
            ForEach(TunableColor.allCases, id: \.self) { color in
                Button {
                    selection = color
                } label: {
                    Label { Text(color.rawValue) } icon: { Image(nsImage: Self.swatch(color.resolve(in: tokens))) }
                }
            }
        } label: {
            HStack(spacing: Metrics.space3) {
                Circle().fill(Color(nsColor: selection.resolve(in: tokens).nsColor)).frame(width: Metrics.space5, height: Metrics.space5)
                    .overlay(Circle().stroke(SettingsStyle.separator, lineWidth: Metrics.dividerThickness))
                Text(selection.rawValue)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Menu items take images, not SwiftUI shapes.
    private static func swatch(_ color: ThemeRGB) -> NSImage {
        let side = Metrics.space5
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
