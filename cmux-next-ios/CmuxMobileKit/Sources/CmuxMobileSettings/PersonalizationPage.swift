#if os(iOS)
import CmuxMobileDesign
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let theme = CmuxMobileTheme.standard

/// Settings > Appearance > Personalization (PROTOCOL.md "Appearance"):
/// "Match my Mac" (the default) or this iPhone's own look, from the same
/// options as the Mac's Personalization page and no others: theme, accent,
/// window style (one surface or two-tone), a background picture from Photos
/// (or none) with its opacity and blur. The phone's Accent color choice is
/// the accent of its default theme, so the old Accent color row lives here.
///
/// Layout (picked from three gallery variants, `PersonalizationGallery`):
/// theme cards first, each a small drawing of the phone in that theme, as
/// T3 Code and Linear show themes; the rest in grouped rows.
struct PersonalizationPage: View {
    @State var model: PersonalizationModel

    var body: some View {
        List {
            PersonalizationSourcePicker(model: model)
            if model.choice.mode == .matchMac {
                PersonalizationMacSection(model: model)
            } else {
                PersonalizationThemeCards(model: model)
                PersonalizationAccentSection(model: model)
                PersonalizationWindowSection(model: model)
                PersonalizationBackgroundSection(model: model)
            }
        }
        .settingsPage("Personalization")
        .animation(theme.motion.snap.animation.unlessReduceMotion, value: model.choice.mode)
    }
}

/// The page's state: the stored choice, applied as it changes.
@MainActor
@Observable
final class PersonalizationModel {
    var choice: CmuxMobilePersonalization {
        didSet {
            guard choice != oldValue else { return }
            appearance.personalization = choice
            if choice.accent != oldValue.accent, let named = CmuxMobileAccent(rawValue: choice.accent) {
                // The default theme's accent is the phone's Accent color (one choice, one place).
                accents.accent = named
            }
        }
    }
    var importingPicture = false
    let appearance: CmuxMobileAppearance
    let accents: CmuxMobileAccentTheme

    init(appearance: CmuxMobileAppearance = .shared, accents: CmuxMobileAccentTheme = .shared) {
        self.appearance = appearance
        self.accents = accents
        var choice = appearance.personalization
        if choice.accent == "neutral", accents.accent != .neutral { choice.accent = accents.accent.rawValue }
        self.choice = choice
    }

    /// The Mac whose look "Match my Mac" shows, by its theme's names.
    var macThemeName: String? {
        guard let id = appearance.disk.lastMacID, let snapshot = appearance.disk.snapshot(macID: id) else { return nil }
        let dark = snapshot.theme?.dark?.name, light = snapshot.theme?.light?.name
        if let dark, let light, dark != light { return "\(light) / \(dark)" }
        return dark ?? light
    }

    /// Keeps a Photos pick: downsampled so its long side is at most 2560 px
    /// (as the Mac exports its backdrop), JPEG 0.85, in the phone's own store.
    func importPicture(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importingPicture = true
        defer { importingPicture = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let jpeg = await Task.detached(priority: .userInitiated) { Self.jpeg(from: data) }.value
        guard let jpeg, let sha = appearance.disk.storePhoneImage(jpeg) else { return }
        choice.background = sha
    }

    nonisolated static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Sections (shared by the page and its gallery variants)

/// "Match my Mac" or "This iPhone".
struct PersonalizationSourcePicker: View {
    let model: PersonalizationModel

    var body: some View {
        Section {
            Picker("Look", selection: Binding(get: { model.choice.mode }, set: { model.choice.mode = $0 })) {
                Text("Match my Mac").tag(CmuxMobilePersonalization.Mode.matchMac)
                Text("This iPhone").tag(CmuxMobilePersonalization.Mode.phone)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("personalization.mode")
        } footer: {
            Text(model.choice.mode == .matchMac
                 ? "Uses the theme, background and colors of the Mac you connected to last."
                 : "Uses this look on this iPhone, whichever Mac you connect to.")
        }
    }
}

struct PersonalizationMacSection: View {
    let model: PersonalizationModel

    var body: some View {
        Section {
            LabeledContent("Theme", value: model.macThemeName ?? String(localized: "Not connected yet"))
                .foregroundStyle(theme.colors.label)
        } footer: {
            Text("Change the look on your Mac in Settings > Personalization. This iPhone follows it.")
        }
    }
}

/// Every theme as a card drawing this phone in it (the selected one ringed).
struct PersonalizationThemeCards: View {
    let model: PersonalizationModel
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(CmuxMobileThemeCatalog.entries) { entry in
                    ThemeCard(entry: entry, accent: model.choice.accent, selected: entry.id == model.choice.theme) {
                        model.choice.theme = entry.id
                        theme.haptics.selection()
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        } header: {
            Text("Theme")
        }
    }
}

/// A theme as a list of rows with a three-dot swatch (gallery variant A).
struct PersonalizationThemeRows: View {
    let model: PersonalizationModel

    var body: some View {
        Section("Theme") {
            ForEach(CmuxMobileThemeCatalog.entries) { entry in
                Button {
                    model.choice.theme = entry.id
                    theme.haptics.selection()
                } label: {
                    HStack(spacing: CmuxMobileListColumn.groupedGap) {
                        ThemeDots(entry: entry, accent: model.choice.accent)
                        Text(verbatim: entry.name).foregroundStyle(theme.colors.label)
                        Spacer()
                        if entry.id == model.choice.theme {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(theme.colors.label)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(entry.id == model.choice.theme ? .isSelected : [])
            }
        }
    }
}

struct PersonalizationAccentSection: View {
    let model: PersonalizationModel

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(CmuxMobilePersonalization.accents, id: \.self) { name in
                        AccentDot(name: name, themeID: model.choice.theme, selected: name == model.choice.accent) {
                            model.choice.accent = name
                            theme.haptics.selection()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Accent")
        } footer: {
            Text("Colors Send, selection and other highlights, from the theme's own palette.")
        }
    }
}

struct PersonalizationWindowSection: View {
    let model: PersonalizationModel

    var body: some View {
        Section("Window style") {
            HStack(spacing: 12) {
                ForEach(CmuxMobilePersonalization.chromeStyles, id: \.self) { style in
                    let selected = style == model.choice.chromeStyle
                    Button {
                        model.choice.chromeStyle = style
                        theme.haptics.selection()
                    } label: {
                        VStack(spacing: 8) {
                            WindowStylePreview(twoTone: style == "two-tone")
                                .frame(height: 64)
                                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(selected ? theme.colors.label.color : theme.colors.separator.color, lineWidth: selected ? 2 : 0.5)
                                }
                            Text(style == "two-tone" ? "Two-tone" : "One color")
                                .font(theme.type.meta.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? theme.colors.label : theme.colors.label2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
    }
}

struct PersonalizationBackgroundSection: View {
    let model: PersonalizationModel
    @State private var pick: PhotosPickerItem?

    var body: some View {
        Section {
            PhotosPicker(selection: $pick, matching: .images) {
                HStack {
                    Text(model.choice.background == nil ? "Choose from Photos" : "Change Picture")
                        .foregroundStyle(theme.colors.label)
                    Spacer()
                    if model.importingPicture { ProgressView() }
                }
            }
            .accessibilityIdentifier("personalization.background.choose")
            .onChange(of: pick) { _, item in Task { await model.importPicture(item) } }
            if model.choice.background != nil {
                Button("No Background", role: .destructive) { model.choice.background = nil }
                SliderRow(title: "Opacity", value: Binding(get: { model.choice.backgroundOpacity }, set: { model.choice.backgroundOpacity = $0 }),
                          range: 0.1...1, format: { "\(Int(($0 * 100).rounded())) %" })
                SliderRow(title: "Blur", value: Binding(get: { model.choice.backgroundBlur }, set: { model.choice.backgroundBlur = $0 }),
                          range: 0...40, format: { "\(Int($0.rounded())) pt" })
            }
        } header: {
            Text("Background")
        } footer: {
            Text("A picture behind every screen, under the glass.")
        }
    }
}

// MARK: - Pieces

struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(theme.colors.label)
                Spacer()
                Text(verbatim: format(value)).monospacedDigit().foregroundStyle(theme.colors.label2)
            }
            Slider(value: $value, in: range).tint(theme.colors.accent.color)
        }
    }
}

/// The colors of a theme as this phone derives them (cached per theme and accent).
@MainActor
enum ThemePreviewColors {
    private static var cache: [String: CmuxMobileResolvedAppearance] = [:]

    static func look(_ entry: CmuxMobileThemeCatalog.Entry, accent: String) -> CmuxMobileResolvedAppearance? {
        let key = "\(entry.id)|\(accent)"
        if let cached = cache[key] { return cached }
        var choice = CmuxMobilePersonalization()
        choice.mode = .phone
        choice.theme = entry.id == CmuxMobileThemeCatalog.defaultID ? "default" : entry.id
        choice.accent = accent
        // The default theme as a theme (its neutral look has no snapshot): a picture-less pair.
        let snapshot = choice.snapshot() ?? CmuxMobileAppearanceSnapshot(
            revision: 0,
            theme: .init(dark: .init(name: entry.name, input: entry.dark), light: .init(name: entry.name, input: entry.light ?? entry.dark)),
            accent: accent)
        let look = CmuxMobileAppearanceResolver.resolve(snapshot, backgroundURL: nil)
        cache[key] = look
        return look
    }
}

/// A theme card: the phone in that theme (sidebar strip, a chat bubble, a
/// terminal line, the accent), and its name under it.
struct ThemeCard: View {
    let entry: CmuxMobileThemeCatalog.Entry
    let accent: String
    let selected: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 92)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? theme.colors.label.color : theme.colors.separator.color, lineWidth: selected ? 2 : 0.5)
                    }
                Text(verbatim: entry.name)
                    .font(theme.type.meta.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.colors.label : theme.colors.label2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: entry.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("personalization.theme.\(entry.id)")
    }

    @ViewBuilder private var preview: some View {
        let dark = scheme == .dark
        if let look = ThemePreviewColors.look(entry, accent: accent) {
            let c = { (role: CmuxMobileColorRole) in Color(uiColor: look.palette[role].value(dark: dark, highContrast: false).uiColor) }
            let ansi = look.terminal.colors(dark: dark).palette
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<4, id: \.self) { row in
                        Capsule().fill(row == 0 ? c(.fillSelected) : c(.fill)).frame(height: 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
                .frame(width: 34)
                .background(c(.sidebarShade))
                VStack(alignment: .trailing, spacing: 6) {
                    Capsule().fill(c(.bubble)).frame(width: 44, height: 12)
                    Capsule().fill(c(.label2)).frame(height: 4).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach([2, 4, 5, 3], id: \.self) { i in
                            Capsule().fill(i < ansi.count ? Color(uiColor: ansi[i].uiColor) : c(.label3)).frame(width: 12, height: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Capsule().fill(c(.fill)).frame(height: 14)
                        Circle().fill(c(.accent)).frame(width: 14, height: 14)
                    }
                }
                .padding(8)
            }
            .background(c(.terminalBackground))
        } else {
            theme.colors.bg.color
        }
    }
}

/// A theme's background, foreground and accent as three overlapping dots.
struct ThemeDots: View {
    let entry: CmuxMobileThemeCatalog.Entry
    let accent: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let look = ThemePreviewColors.look(entry, accent: accent)
        let color = { (role: CmuxMobileColorRole) in
            look.map { Color(uiColor: $0.palette[role].value(dark: dark, highContrast: false).uiColor) } ?? .gray
        }
        HStack(spacing: -6) {
            Circle().fill(color(.terminalBackground))
            Circle().fill(color(.label))
            Circle().fill(color(.accent))
        }
        .overlay { Capsule().strokeBorder(theme.colors.separator, lineWidth: 0.5) }
        .frame(width: 44, height: 20)
        .accessibilityHidden(true)
    }
}

/// One accent as a dot in the chosen theme's color for it.
struct AccentDot: View {
    let name: String
    let themeID: String
    let selected: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let entry = CmuxMobileThemeCatalog.entry(themeID)
        let look = ThemePreviewColors.look(entry, accent: name)
        let fill = look.map { Color(uiColor: $0.palette[.accent].value(dark: scheme == .dark, highContrast: false).uiColor) } ?? .gray
        Button(action: choose) {
            VStack(spacing: 6) {
                Circle().fill(fill)
                    .overlay { Circle().strokeBorder(theme.colors.separator, lineWidth: 0.5) }
                    .frame(width: 30, height: 30)
                    .padding(3)
                    .overlay { Circle().strokeBorder(selected ? theme.colors.label.color : .clear, lineWidth: 2) }
                Text(verbatim: Self.title(name)).font(.caption2).foregroundStyle(selected ? theme.colors.label : theme.colors.label2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Self.title(name)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func title(_ name: String) -> String {
        switch name {
        case "neutral": String(localized: "Default")
        case "theme": String(localized: "Theme")
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// A window drawn in one color, or two-tone (the sidebar a shade apart).
struct WindowStylePreview: View {
    let twoTone: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(twoTone ? theme.colors.fillPressed.color : theme.colors.surface.color).frame(width: 36)
            if !twoTone { Rectangle().fill(theme.colors.separator.color).frame(width: 0.5) }
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(theme.colors.label3.color).frame(width: 50, height: 5)
                Capsule().fill(theme.colors.label3.color).frame(width: 34, height: 5)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.colors.surface.color)
        }
    }
}
#endif
