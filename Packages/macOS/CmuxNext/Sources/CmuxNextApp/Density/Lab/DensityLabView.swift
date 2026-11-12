#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import SwiftUI
import UniformTypeIdentifiers

/// The Density Lab: the controls for one density on the left, and the main window's top-left corner
/// at every density on the right, at the size it ships at, beside an optional reference image.
struct DensityLabView: View {
    @Bindable var model: DensityLabModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { controls.padding(16) }
                .frame(width: 360)
            Divider()
            gallery
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Density", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.densities) { density in Text(density.name).tag(density.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.selectedIsEdited ? "\(model.selected.name) (edited; the app draws it now)" : "\(model.selected.name) (built-in values)")
                .foregroundStyle(.secondary)

            section("Scale") {
                slider("Level", value: field(\.level), range: DensityTokens.levelRange, step: 0.05,
                       note: "0 Compact, 1 Comfortable")
                slider("Spacing", value: field(\.spacing), range: DensityTokens.spacingRange, step: 0.05, note: "padding ×")
                optionalSlider("Body text", value: Binding(get: { model.selected.fontSize }, set: { size in
                    var density = model.selected
                    density.fontSize = size
                    model.selected = density
                }), fallback: Double(model.selected.levelBodySize), range: DensityTokens.fontSizeRange, step: 0.5, unit: "pt")
            }

            section("Exact metrics (off: follow the level)") {
                ForEach(DensityLabModel.metrics, id: \.tunable.name) { metric in
                    optionalSlider(metric.tunable.name, value: Binding(
                        get: { model.selected.tokens[metric.tunable.name] },
                        set: { model.setToken(metric.tunable.name, $0) }),
                        fallback: model.resolved(metric.tunable), range: metric.range, step: 1, unit: "pt")
                }
            }

            section("Captures") {
                HStack {
                    Button(model.isCapturing ? "Capturing…" : "Capture all densities") { Task { await model.captureAll() } }
                        .disabled(model.isCapturing)
                    Button("Reference image…") { chooseReference() }
                    if model.reference != nil { Button("Clear") { model.reference = nil } }
                }
                slider("Crop width", value: $model.cropWidth, range: 240...1400, step: 10, note: "pt")
                slider("Crop height", value: $model.cropHeight, range: 160...900, step: 10, note: "pt")
            }

            section("Save") {
                HStack {
                    Button("Save") { model.save() }.keyboardShortcut("s")
                    Button("Copy Swift") { model.copySwift() }
                    Button("Reset \(model.selected.name)") { model.resetSelected() }.disabled(!model.selectedIsEdited)
                }
                Text(model.status.isEmpty ? model.fileURL.path : model.status)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func field(_ path: WritableKeyPath<DensityTokens, Double>) -> Binding<Double> {
        Binding(get: { model.selected[keyPath: path] }, set: { value in
            var density = model.selected
            density[keyPath: path] = value
            model.selected = density
        })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).bold()
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Self.format(value.wrappedValue)) \(note)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// A value that is either set (the toggle is on and the slider moves it) or follows `fallback`.
    private func optionalSlider(_ title: String, value: Binding<Double?>, fallback: Double, range: ClosedRange<Double>,
                                step: Double, unit: String) -> some View {
        let isSet = value.wrappedValue != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(title, isOn: Binding(get: { isSet }, set: { on in
                    value.wrappedValue = on ? min(max(fallback, range.lowerBound), range.upperBound) : nil
                }))
                Spacer()
                Text("\(Self.format(value.wrappedValue ?? fallback)) \(unit)\(isSet ? "" : " (level)")")
                    .monospacedDigit().foregroundStyle(isSet ? .primary : .secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }), in: range, step: step)
                .disabled(!isSet)
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }

    // MARK: Gallery

    private var gallery: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                if model.captures.isEmpty {
                    Text("Press Capture all densities to see the main window at each density, side by side.")
                        .foregroundStyle(.secondary)
                }
                if let reference = model.reference {
                    tile("Reference", image: reference, scale: model.referenceScale, selected: false)
                }
                ForEach(model.densities) { density in
                    if let image = model.captures[density.id] {
                        tile(density.name, image: image, scale: model.captureScale, selected: density.id == model.selectedID)
                            .onTapGesture { model.select(density.id) }
                    }
                }
            }
            .padding(16)
        }
    }

    /// The top-left `cropWidth` × `cropHeight` points of `image`, drawn at one point per point.
    private func tile(_ title: String, image: CGImage, scale: CGFloat, selected: Bool) -> some View {
        let width = min(CGFloat(model.cropWidth), CGFloat(image.width) / scale)
        let height = min(CGFloat(model.cropHeight), CGFloat(image.height) / scale)
        let crop = image.cropping(to: CGRect(x: 0, y: 0, width: width * scale, height: height * scale)) ?? image
        return VStack(alignment: .leading, spacing: 6) {
            Text(selected ? "\(title) (editing)" : title).bold()
            Image(decorative: crop, scale: scale)
                .overlay(Rectangle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 2 : 1))
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
            // A Retina screenshot's pixels over its points (144 dpi reads as 2), so it shows at its own point size.
            model.referenceScale = max(1, (CGFloat(cg.width) / max(image.size.width, 1)).rounded())
            model.reference = cg
        }
    }
}
#endif
