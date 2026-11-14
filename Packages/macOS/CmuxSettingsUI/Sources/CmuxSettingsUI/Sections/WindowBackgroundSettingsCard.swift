import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI
import UniformTypeIdentifiers

/// **Themes → Window Background** card: one picture behind the sidebar,
/// titlebar and every terminal pane, with its opacity and fit.
///
/// Each row writes its `windowBackground.*` key to `UserDefaults`; open main
/// windows observe those keys and redraw at once.
@MainActor
struct WindowBackgroundSettingsCard: View {
    @State private var image: DefaultsValueModel<String>
    @State private var imageOpacity: DefaultsValueModel<Double>
    @State private var imageFit: DefaultsValueModel<WindowBackgroundImageFit>

    private static let columnWidth: CGFloat = 236

    /// Creates the card.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store the image settings are read from and written to.
    ///   - catalog: The catalog that provides the `windowBackground.*` keys.
    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _image = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.windowBackground.image))
        _imageOpacity = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.windowBackground.imageOpacity))
        _imageFit = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.windowBackground.imageFit))
    }

    var body: some View {
        SettingsCard {
            imageRow
            SettingsCardDivider()
            opacityRow
            SettingsCardDivider()
            fitRow
        }
        .task { startSettingsObservation([image, imageOpacity, imageFit]) }
    }

    private var hasImage: Bool {
        WindowBackgroundImageSettings(path: image.current).isEnabled
    }

    private var imageRow: some View {
        SettingsCardRow(
            configurationReview: .json("windowBackground.image"),
            Self.imageTitle,
            subtitle: String(
                localized: "settings.themes.windowBackground.image.subtitle",
                defaultValue: "One picture behind the sidebar, titlebar and terminals. While set, it replaces window transparency."
            ),
            controlWidth: Self.columnWidth
        ) {
            HStack(spacing: 8) {
                Text(hasImage
                    ? (image.current as NSString).lastPathComponent
                    : String(localized: "settings.themes.windowBackground.image.none", defaultValue: "None"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(hasImage ? .primary : .secondary)
                    .help(image.current)
                Spacer(minLength: 0)
                if hasImage {
                    Button(String(localized: "settings.themes.windowBackground.image.remove", defaultValue: "Remove")) {
                        image.set("")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsWindowBackgroundImageRemoveButton")
                }
                Button(String(localized: "settings.themes.windowBackground.image.choose", defaultValue: "Choose…")) {
                    chooseImage()
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsWindowBackgroundImageChooseButton")
            }
        }
    }

    private var opacityRow: some View {
        SettingsCardRow(
            configurationReview: .json("windowBackground.imageOpacity"),
            Self.opacityTitle,
            subtitle: String(
                localized: "settings.themes.windowBackground.imageOpacity.subtitle",
                defaultValue: "Lower values keep text easier to read."
            ),
            controlWidth: Self.columnWidth
        ) {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { imageOpacity.current }, set: { imageOpacity.set($0) }),
                    in: 0...1,
                    step: 0.05
                )
                .accessibilityIdentifier("SettingsWindowBackgroundImageOpacitySlider")
                Text(imageOpacity.current, format: .percent.precision(.fractionLength(0)))
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!hasImage)
        }
    }

    private var fitRow: some View {
        SettingsCardRow(
            configurationReview: .json("windowBackground.imageFit"),
            Self.fitTitle,
            controlWidth: Self.columnWidth
        ) {
            Picker("", selection: Binding(get: { imageFit.current }, set: { imageFit.set($0) })) {
                ForEach(WindowBackgroundImageFit.allCases, id: \.self) { fit in
                    Text(Self.displayName(for: fit)).tag(fit)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!hasImage)
            .accessibilityIdentifier("SettingsWindowBackgroundImageFitPicker")
        }
    }

    /// Presents an image picker and stores the chosen file, abbreviated to
    /// `~/…` when it is in the home folder so cmux.json stays portable.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = String(
            localized: "settings.themes.windowBackground.image.panelTitle",
            defaultValue: "Choose a Background Image"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        image.set((url.path as NSString).abbreviatingWithTildeInPath)
    }

    /// The image row title, shared with the Settings search entry.
    nonisolated static var imageTitle: String {
        String(localized: "settings.themes.windowBackground.image", defaultValue: "Background Image")
    }

    /// The opacity row title, shared with the Settings search entry.
    nonisolated static var opacityTitle: String {
        String(localized: "settings.themes.windowBackground.imageOpacity", defaultValue: "Background Image Opacity")
    }

    /// The fit row title, shared with the Settings search entry.
    nonisolated static var fitTitle: String {
        String(localized: "settings.themes.windowBackground.imageFit", defaultValue: "Background Image Fit")
    }

    private static func displayName(for fit: WindowBackgroundImageFit) -> String {
        switch fit {
        case .cover:
            return String(localized: "settings.themes.windowBackground.imageFit.cover", defaultValue: "Fill Window")
        case .contain:
            return String(localized: "settings.themes.windowBackground.imageFit.contain", defaultValue: "Fit Inside")
        case .stretch:
            return String(localized: "settings.themes.windowBackground.imageFit.stretch", defaultValue: "Stretch")
        }
    }
}
