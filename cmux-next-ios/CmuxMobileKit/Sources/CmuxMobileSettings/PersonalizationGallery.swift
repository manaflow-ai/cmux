#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// DEBUG: the three layouts Personalization was picked from, as gallery
/// scenes (`-cmux-mobile-recovery-gallery personalization-a|b|c`), each on
/// "This iPhone" so every option shows:
/// - `a`: rows: each theme a row with a three-dot swatch and a checkmark,
///   as Accent color's page lists accents (compact, but a theme reads only as dots);
/// - `b` (shipping): theme cards drawing the phone in each theme, then the
///   options in grouped rows (T3 Code's and Linear's theme pickers);
/// - `c`: a live preview card of the phone on top, then themes in a
///   horizontal strip (Codex's preview-first page; the strip hides most themes).
public struct PersonalizationGallery: View {
    let variant: String
    @State private var model: PersonalizationModel

    public init(variant: String) {
        self.variant = variant
        let model = PersonalizationModel()
        if model.choice.mode != .phone {
            var choice = model.choice
            choice.mode = .phone
            if choice.theme == CmuxMobileThemeCatalog.defaultID { choice.theme = "catppuccin" }
            if choice.accent == "neutral" { choice.accent = "magenta" }
            choice.chromeStyle = "two-tone"
            model.choice = choice
        }
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            switch variant {
            case "a": rows
            case "c": previewFirst
            default: PersonalizationPage(model: model)
            }
        }
    }

    private var rows: some View {
        List {
            PersonalizationSourcePicker(model: model)
            PersonalizationThemeRows(model: model)
            PersonalizationAccentSection(model: model)
            PersonalizationWindowSection(model: model)
            PersonalizationBackgroundSection(model: model)
        }
        .settingsPage("Personalization")
    }

    private var previewFirst: some View {
        List {
            PersonalizationSourcePicker(model: model)
            Section {
                ThemeCard(entry: CmuxMobileThemeCatalog.entry(model.choice.theme), accent: model.choice.accent, selected: false) {}
                    .scaleEffect(x: 1, y: 1.6, anchor: .top)
                    .frame(height: 170, alignment: .top)
                    .listRowBackground(Color.clear)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(CmuxMobileThemeCatalog.entries) { entry in
                            let selected = entry.id == model.choice.theme
                            Button { model.choice.theme = entry.id } label: {
                                Text(verbatim: entry.name)
                                    .font(theme.type.chip)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .foregroundStyle(selected ? theme.colors.onAccent : theme.colors.label)
                                    .background(selected ? theme.colors.accent.color : theme.colors.fill.color, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: { Text("Theme") }
            PersonalizationAccentSection(model: model)
            PersonalizationWindowSection(model: model)
            PersonalizationBackgroundSection(model: model)
        }
        .settingsPage("Personalization")
    }
}
#endif
