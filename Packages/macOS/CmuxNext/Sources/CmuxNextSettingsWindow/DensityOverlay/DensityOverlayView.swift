import CmuxNextDesign
import SwiftUI

/// The Density Overlay Playground's window content: a toolbar (reference, mode, opacity, zoom, tolerance, offset
/// nudges, Live, Controls) over a canvas that lays a reference capture on cmux's own browser chrome, and a status line
/// with the pixel diff. Pixels draw without smoothing, so the zoom is a loupe.
struct DensityOverlayView: View {
    let model: DensityOverlayModel
    let openControls: () -> Void

    var body: some View {
        content(theme: SettingsTheme.shared.tokens)
    }

    private func content(theme _: some Any) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, Metrics.space5)
                .padding(.top, Metrics.titlebarHeight)
                .padding(.bottom, Metrics.space3)
            Rectangle().fill(SettingsStyle.separator).frame(height: Metrics.dividerThickness)
            ScrollView([.horizontal, .vertical]) {
                canvas.padding(Metrics.space5)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.mode == .flip { model.flip() } }
            }
            Rectangle().fill(SettingsStyle.separator).frame(height: Metrics.dividerThickness)
            Text(status)
                .font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, Metrics.space5).padding(.vertical, Metrics.space3)
                .accessibilityIdentifier("cmux.densityOverlay.status")
        }
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
        .onAppear { model.appear() }
        .onChange(of: TunableStore.shared.revision) { model.chromeDidChange() }
        .onChange(of: Metrics.tokens) { model.chromeDidChange() }
    }

    private var toolbar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(spacing: Metrics.space3) {
                Menu(model.referenceName ?? DensityOverlayStrings.reference) {
                    ForEach(model.builtInReferences, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.loadReference(url) }
                    }
                    Divider()
                    Button(DensityOverlayStrings.chooseReference) { model.chooseReference() }
                }
                .fixedSize()
                .accessibilityIdentifier("cmux.densityOverlay.reference")
                Picker("", selection: $model.mode) {
                    ForEach(DensityOverlayModel.Mode.allCases) { Text(DensityOverlayStrings.mode($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
                Toggle(DensityOverlayStrings.live, isOn: $model.isLive).toggleStyle(.checkbox)
                Button(DensityOverlayStrings.capture) { model.capture() }.buttonStyle(SettingsButtonStyle())
                Button(DensityOverlayStrings.controls, action: openControls).buttonStyle(SettingsButtonStyle())
            }
            HStack(spacing: Metrics.space5) {
                labeled(DensityOverlayStrings.opacity) { Slider(value: $model.opacity, in: 0...1).frame(width: 110) }
                labeled(DensityOverlayStrings.zoom) { Slider(value: $model.zoom, in: 1...8, step: 1).frame(width: 110) }
                labeled(DensityOverlayStrings.threshold) { Slider(value: $model.threshold, in: 0...96, step: 4).frame(width: 90) }
                HStack(spacing: Metrics.space1) {
                    nudge("←", dx: -1, dy: 0); nudge("→", dx: 1, dy: 0); nudge("↑", dx: 0, dy: -1); nudge("↓", dx: 0, dy: 1)
                    Text(DensityOverlayStrings.offset(Int(model.offset.x), Int(model.offset.y)))
                        .font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary).monospacedDigit()
                }
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: Metrics.space2) {
            Text(title).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
            control()
        }
    }

    private func nudge(_ arrow: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button(arrow) { model.nudge(dx: dx, dy: dy) }
            .buttonStyle(SettingsButtonStyle())
            .accessibilityLabel(DensityOverlayStrings.offset(Int(dx), Int(dy)))
    }

    @ViewBuilder private var canvas: some View {
        let zoom = model.zoom / 2 // the captures are 2x: one image pixel is half a point at zoom 1
        switch model.mode {
        case .sideBySide:
            VStack(alignment: .leading, spacing: Metrics.space3) {
                pixels(model.reference, zoom: zoom)
                pixels(model.live, zoom: zoom)
            }
        case .flip:
            pixels(model.flipShowsReference ? model.reference : model.live, zoom: zoom)
        case .overlay, .difference:
            ZStack(alignment: .topLeading) {
                pixels(model.live, zoom: zoom)
                pixels(model.reference, zoom: zoom)
                    .offset(x: model.offset.x * zoom, y: model.offset.y * zoom)
                    .opacity(model.mode == .difference ? 1 : model.opacity)
                    .blendMode(model.mode == .difference ? .difference : .normal)
            }
            .compositingGroup()
        }
    }

    @ViewBuilder private func pixels(_ image: CGImage?, zoom: Double) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
        }
    }

    private var status: String {
        if model.noBrowserPane { return DensityOverlayStrings.noBrowserPane }
        guard model.reference != nil else { return DensityOverlayStrings.noReference }
        guard let diff = model.diff else { return "" }
        guard let bounds = diff.bounds else { return DensityOverlayStrings.matches }
        let percent = diff.fraction.formatted(.percent.precision(.fractionLength(1)))
        return DensityOverlayStrings.differing(diff.differing, of: diff.total, percent: percent) + " · "
            + DensityOverlayStrings.differenceBounds(Int(bounds.minX), Int(bounds.maxX) - 1, Int(bounds.minY), Int(bounds.maxY) - 1)
    }
}
