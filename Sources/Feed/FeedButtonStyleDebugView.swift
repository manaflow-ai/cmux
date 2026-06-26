#if DEBUG
import AppKit
import SwiftUI

private struct FeedButtonDebugPresetSection: Identifiable {
    let id: String
    let label: String
    let presets: [FeedButtonDebugPreset]

    static var all: [FeedButtonDebugPresetSection] {
        [
            FeedButtonDebugPresetSection(
                id: "base",
                label: String(localized: "feed.buttonDebug.section.base", defaultValue: "Base"),
                presets: [.solidClassic, .minimalFlat]
            ),
            FeedButtonDebugPresetSection(
                id: "native",
                label: String(localized: "feed.buttonDebug.section.nativeGlass", defaultValue: "Native Glass"),
                presets: [
                    .standardLiquidGlass,
                    .tintedLiquidGlass,
                    .nativeGlass,
                    .nativeProminentGlass,
                    .clearGlass,
                    .nativeBlue,
                ]
            ),
            FeedButtonDebugPresetSection(
                id: "command",
                label: String(localized: "feed.buttonDebug.section.command", defaultValue: "Command"),
                presets: [.commandDark, .commandLight]
            ),
            FeedButtonDebugPresetSection(
                id: "material",
                label: String(localized: "feed.buttonDebug.section.material", defaultValue: "Material"),
                presets: [
                    .raycastGlass,
                    .compactGlass,
                    .liquidCapsule,
                    .liquidMono,
                    .frostedOutline,
                    .haloGlow,
                    .softHalo,
                    .hairlineGlass,
                ]
            ),
        ]
    }
}

struct FeedButtonStyleDebugView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.feedButtonDebugStore) private var debugStore
    @AppStorage(FeedButtonDebugStore.styleKey)
    private var styleRaw = FeedButtonDebugVisualStyle.solid.rawValue
    @AppStorage(FeedButtonDebugStore.paletteKey)
    private var paletteRaw = FeedButtonDebugPalettePreset.system.rawValue
    @AppStorage(FeedButtonDebugStore.compactCornerRadiusKey)
    private var compactCornerRadius = 5.0
    @AppStorage(FeedButtonDebugStore.mediumCornerRadiusKey)
    private var mediumCornerRadius = 6.0
    @AppStorage(FeedButtonDebugStore.compactHorizontalPaddingKey)
    private var compactHorizontalPadding = 8.0
    @AppStorage(FeedButtonDebugStore.mediumHorizontalPaddingKey)
    private var mediumHorizontalPadding = 12.0
    @AppStorage(FeedButtonDebugStore.compactVerticalPaddingKey)
    private var compactVerticalPadding = 4.0
    @AppStorage(FeedButtonDebugStore.mediumVerticalPaddingKey)
    private var mediumVerticalPadding = 5.0
    @AppStorage(FeedButtonDebugStore.glassTintOpacityKey)
    private var glassTintOpacity = 0.42
    @AppStorage(FeedButtonDebugStore.borderWidthKey)
    private var borderWidth = 0.9
    @State private var selectedKind: FeedButton.Kind = .primary
    private let palettePreviewKinds: [FeedButton.Kind] = [.ghost, .primary, .success, .warning, .destructive]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                previewRail
                paletteControls
                styleControls
                kindPicker
                colorControls
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onChange(of: styleRaw) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: paletteRaw) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: compactCornerRadius) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: mediumCornerRadius) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: compactHorizontalPadding) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: mediumHorizontalPadding) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: compactVerticalPadding) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: mediumVerticalPadding) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: glassTintOpacity) { _, _ in debugStore.bumpGeneration() }
        .onChange(of: borderWidth) { _, _ in debugStore.bumpGeneration() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "feed.buttonDebug.title", defaultValue: "Feed Buttons"))
                    .font(.system(size: 17, weight: .semibold))
                Text(
                    String(
                        localized: "feed.buttonDebug.subtitle",
                        defaultValue: "Tune every Feed button kind live."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "feed.buttonDebug.reset", defaultValue: "Reset")) {
                debugStore.reset()
                styleRaw = FeedButtonDebugVisualStyle.solid.rawValue
                paletteRaw = FeedButtonDebugPalettePreset.system.rawValue
                compactCornerRadius = 5.0
                mediumCornerRadius = 6.0
                compactHorizontalPadding = 8.0
                mediumHorizontalPadding = 12.0
                compactVerticalPadding = 4.0
                mediumVerticalPadding = 5.0
                glassTintOpacity = 0.42
                borderWidth = 0.9
            }
        }
    }

    private var paletteControls: some View {
        GroupBox(String(localized: "feed.buttonDebug.palette", defaultValue: "Palette")) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(FeedButtonDebugPalettePreset.allCases) { palette in
                        paletteButton(palette)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    palettePreviewRow(
                        label: String(localized: "feed.buttonDebug.palette.light", defaultValue: "Light"),
                        colorScheme: .light,
                        background: Color(nsColor: .windowBackgroundColor)
                    )
                    palettePreviewRow(
                        label: String(localized: "feed.buttonDebug.palette.dark", defaultValue: "Dark"),
                        colorScheme: .dark,
                        background: Color(red: 0.08, green: 0.09, blue: 0.10)
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func paletteButton(_ palette: FeedButtonDebugPalettePreset) -> some View {
        Button {
            applyPalette(palette)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: palette == activePalette ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                paletteSwatches(palette)
                Text(palette.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette == activePalette
                          ? Color.accentColor.opacity(0.18)
                          : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        palette == activePalette
                            ? Color.accentColor.opacity(0.5)
                            : Color.primary.opacity(0.08),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func paletteSwatches(_ palette: FeedButtonDebugPalettePreset) -> some View {
        HStack(spacing: 2) {
            ForEach(palettePreviewKinds) { kind in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(swatchColor(for: palette, kind: kind, colorScheme: colorScheme))
                    .frame(width: 9, height: 10)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func swatchColor(
        for palette: FeedButtonDebugPalettePreset,
        kind: FeedButton.Kind,
        colorScheme: ColorScheme
    ) -> Color {
        palette.color(for: kind, role: .background, colorScheme: colorScheme)
            ?? debugStore.fallbackColor(
                for: kind,
                role: .background,
                colorScheme: colorScheme
            )
    }

    private func palettePreviewRow(
        label: String,
        colorScheme previewColorScheme: ColorScheme,
        background: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(previewColorScheme == .dark ? Color.white.opacity(0.70) : Color.black.opacity(0.58))
                .frame(width: 34, alignment: .leading)
            ForEach([FeedButton.Kind.primary, .success, .warning, .destructive]) { kind in
                FeedButton(label: kind.debugLabel, kind: kind, size: .compact) {
                    selectedKind = kind
                }
                .environment(\.colorScheme, previewColorScheme)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    previewColorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.08),
                    lineWidth: 0.8
                )
        )
    }

    private var previewRail: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    previewRailContent
                }
            } else {
                previewRailContent
            }
            #else
            previewRailContent
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var previewRailContent: some View {
        HStack(spacing: 8) {
            ForEach(FeedButton.Kind.allCases) { kind in
                FeedButton(
                    label: kind.debugLabel,
                    kind: kind,
                    size: kind == .ghost ? .compact : .medium,
                    isSelected: selectedKind == kind
                ) {
                    selectedKind = kind
                }
            }
        }
    }

    private var styleControls: some View {
        GroupBox(String(localized: "feed.buttonDebug.style", defaultValue: "Style")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    String(localized: "feed.buttonDebug.style", defaultValue: "Style"),
                    selection: $styleRaw
                ) {
                    ForEach(FeedButtonDebugVisualStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(String(localized: "feed.buttonDebug.variations", defaultValue: "Variations"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(FeedButtonDebugPresetSection.all) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading),
                            ],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(section.presets) { preset in
                                presetButton(preset)
                            }
                        }
                    }
                }

                debugSlider(
                    title: String(localized: "feed.buttonDebug.compactRadius", defaultValue: "Compact radius"),
                    value: $compactCornerRadius,
                    range: 2...14,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.mediumRadius", defaultValue: "Medium radius"),
                    value: $mediumCornerRadius,
                    range: 2...16,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.horizontalPadding", defaultValue: "Horizontal padding"),
                    value: $mediumHorizontalPadding,
                    range: 6...18,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.compactHorizontalPadding", defaultValue: "Compact horizontal padding"),
                    value: $compactHorizontalPadding,
                    range: 5...14,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.compactVerticalPadding", defaultValue: "Compact vertical padding"),
                    value: $compactVerticalPadding,
                    range: 2...9,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.mediumVerticalPadding", defaultValue: "Medium vertical padding"),
                    value: $mediumVerticalPadding,
                    range: 3...11,
                    suffix: "px"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.glassTint", defaultValue: "Glass tint"),
                    value: $glassTintOpacity,
                    range: 0...0.9,
                    suffix: "%"
                )
                debugSlider(
                    title: String(localized: "feed.buttonDebug.borderWidth", defaultValue: "Border"),
                    value: $borderWidth,
                    range: 0.5...2.5,
                    suffix: "px"
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func presetButton(_ preset: FeedButtonDebugPreset) -> some View {
        Button {
            applyPreset(preset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: preset == activePreset ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                Text(preset.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(preset == activePreset
                          ? Color.accentColor.opacity(0.18)
                          : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        preset == activePreset
                            ? Color.accentColor.opacity(0.5)
                            : Color.primary.opacity(0.08),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var kindPicker: some View {
        GroupBox(String(localized: "feed.buttonDebug.kind", defaultValue: "Button Kind")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(FeedButton.Kind.allCases) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: selectedKind == kind ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedKind == kind ? Color.accentColor : Color.secondary)
                            .frame(width: 15)
                        Text(kind.debugLabel)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        FeedButton(label: kind.debugLabel, kind: kind, size: .compact) {
                            selectedKind = kind
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedKind = kind }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var colorControls: some View {
        GroupBox(String(localized: "feed.buttonDebug.colors", defaultValue: "Colors")) {
            VStack(alignment: .leading, spacing: 10) {
                ColorPicker(
                    String(localized: "feed.buttonDebug.background", defaultValue: "Background"),
                    selection: colorBinding(for: selectedKind, role: .background),
                    supportsOpacity: false
                )
                ColorPicker(
                    String(localized: "feed.buttonDebug.hover", defaultValue: "Hover"),
                    selection: colorBinding(for: selectedKind, role: .hoverBackground),
                    supportsOpacity: false
                )
                ColorPicker(
                    String(localized: "feed.buttonDebug.foreground", defaultValue: "Foreground"),
                    selection: colorBinding(for: selectedKind, role: .foreground),
                    supportsOpacity: false
                )
                HStack {
                    Text(String(localized: "feed.buttonDebug.preview", defaultValue: "Preview"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    FeedButton(label: selectedKind.debugLabel, kind: selectedKind, size: .medium) {}
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func colorBinding(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole
    ) -> Binding<Color> {
        Binding(
            get: {
                debugStore.color(for: kind, role: role, colorScheme: colorScheme)
                    ?? debugStore.defaultColor(
                        for: kind,
                        role: role,
                        colorScheme: colorScheme
                    )
            },
            set: { newValue in
                debugStore.setColor(newValue, for: kind, role: role)
            }
        )
    }

    private var activePalette: FeedButtonDebugPalettePreset {
        FeedButtonDebugPalettePreset(rawValue: paletteRaw) ?? .system
    }

    private var activePreset: FeedButtonDebugPreset? {
        FeedButtonDebugPreset.allCases.first { preset in
            styleRaw == preset.style.rawValue
                && compactCornerRadius == preset.compactCornerRadius
                && mediumCornerRadius == preset.mediumCornerRadius
                && compactHorizontalPadding == preset.compactHorizontalPadding
                && mediumHorizontalPadding == preset.mediumHorizontalPadding
                && compactVerticalPadding == preset.compactVerticalPadding
                && mediumVerticalPadding == preset.mediumVerticalPadding
                && glassTintOpacity == preset.glassTintOpacity
                && borderWidth == preset.borderWidth
        }
    }

    private func applyPalette(_ palette: FeedButtonDebugPalettePreset) {
        debugStore.applyPalette(palette)
        paletteRaw = palette.rawValue
    }

    private func applyPreset(_ preset: FeedButtonDebugPreset) {
        debugStore.apply(preset)
        styleRaw = preset.style.rawValue
        if let palette = preset.palette {
            paletteRaw = palette.rawValue
        }
        compactCornerRadius = preset.compactCornerRadius
        mediumCornerRadius = preset.mediumCornerRadius
        compactHorizontalPadding = preset.compactHorizontalPadding
        mediumHorizontalPadding = preset.mediumHorizontalPadding
        compactVerticalPadding = preset.compactVerticalPadding
        mediumVerticalPadding = preset.mediumVerticalPadding
        glassTintOpacity = preset.glassTintOpacity
        borderWidth = preset.borderWidth
    }

    private func debugSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
            Text(sliderValue(value.wrappedValue, suffix: suffix))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func sliderValue(_ value: Double, suffix: String) -> String {
        if suffix == "%" {
            return String(format: "%.0f%%", value * 100)
        }
        return String(format: "%.1f%@", value, suffix)
    }
}
#endif
