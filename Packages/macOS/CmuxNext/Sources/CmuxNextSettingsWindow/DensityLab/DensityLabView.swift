import AppKit
import CmuxNextDesign
import SwiftUI
import UniformTypeIdentifiers

/// The Density Lab: the densities on the left, the selected one's values in the middle, and the main window's
/// top-left corner at every density on the right, at the size it ships at, beside an optional reference image.
struct DensityLabView: View {
    @Bindable var model: DensityLabModel

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 200)
            Divider()
            DensityLabControlsView(model: model).frame(width: 400)
            Divider()
            preview
        }
        .frame(minWidth: 1100, minHeight: 620)
    }

    // MARK: Densities

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
                Section("Built-in") {
                    ForEach(model.builtIns) { density in listRow(density) }
                }
                Section("Yours") {
                    ForEach(model.customs) { density in listRow(density) }
                    if model.customs.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button("New density") { model.newCustom() }
                .help("A new density of your own, made from the selected one")
                .padding(12)
        }
    }

    private func listRow(_ density: DensityTokens) -> some View {
        let edited = DensityPreset(rawValue: density.id).map { $0.tokens != density } ?? false
        return HStack {
            Text(density.name)
            Spacer()
            if edited { Text("edited").foregroundStyle(.secondary) }
        }
        .tag(density.id)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(model.isCapturing ? "Capturing…" : "Capture all") { Task { await model.captureAll() } }
                    .disabled(model.isCapturing)
                    .help("Draws the main window at every density and shows each here. The selected one updates as you edit.")
                Button("Reference image…") { chooseReference() }
                    .help("A screenshot to match, shown above the captures at its own size")
                if model.reference != nil { Button("Clear reference") { model.reference = nil } }
                Spacer()
                Text("Width")
                Slider(value: $model.cropWidth, in: 240...1400).frame(width: 110)
                Text("Height")
                Slider(value: $model.cropHeight, in: 120...900).frame(width: 110)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 20) {
                    if let reference = model.reference {
                        tile("Reference", image: reference, scale: model.referenceScale, selected: false)
                    }
                    ForEach(model.all) { density in
                        if let image = model.captures[density.id] {
                            tile(density.name, image: image, scale: model.captureScale, selected: density.id == model.selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(density.id) }
                        }
                    }
                    if model.captures.isEmpty {
                        Text(model.isCapturing ? "Capturing every density…" : "Press Capture all to see the window at every density.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    /// The top-left `cropWidth` × `cropHeight` points of `image`, drawn at one point per point.
    private func tile(_ title: String, image: CGImage, scale: CGFloat, selected: Bool) -> some View {
        let width = min(CGFloat(model.cropWidth), CGFloat(image.width) / scale)
        let height = min(CGFloat(model.cropHeight), CGFloat(image.height) / scale)
        let crop = image.cropping(to: CGRect(x: 0, y: 0, width: width * scale, height: height * scale)) ?? image
        return VStack(alignment: .leading, spacing: 6) {
            Text(selected ? "\(title) (editing)" : title).font(.headline)
            Image(decorative: crop, scale: scale)
                .overlay(Rectangle().stroke(selected ? Color.primary : Color.secondary.opacity(0.4), lineWidth: selected ? 2 : 1))
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.loadReference(url)
        }
    }
}
