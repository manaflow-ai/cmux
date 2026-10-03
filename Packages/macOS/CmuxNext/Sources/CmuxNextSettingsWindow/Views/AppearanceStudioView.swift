public import CmuxNextDesign
public import SwiftUI

/// The appearance studio (`appearance.customize`, "Customize Appearance…"):
/// a floating glass panel over the window it customizes, so that window is
/// the live preview. The App hosts it on glass, so it paints no background.
/// Every control runs the same actions or writes the same cmux.json keys
/// as Settings, the palette and the CLI; nothing here keeps its own copy.
/// It starts with the theme; background, fonts and the accent join as
/// their own sections.
public struct AppearanceStudioView: View {
    let model: SettingsWindowModel
    let onClose: () -> Void

    public init(model: SettingsWindowModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    /// Draws the studio (and Settings, which shares its colors) in `scope`,
    /// the theme of the window being customized.
    @MainActor
    public static func followTheme(of scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text(SettingsWindowStrings.studioTitle).font(SettingsStyle.title)
                    Text(SettingsWindowStrings.studioSubtitle).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(SettingsStyle.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsStyle.secondary)
                .help(SettingsWindowStrings.studioClose)
                .accessibilityLabel(SettingsWindowStrings.studioClose)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Metrics.space4)
            .padding(.top, Metrics.space4)
            .padding(.bottom, Metrics.space3)
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space4) {
                    ThemeCard()
                    ThemePickerCard(model: model)
                    BackdropArtAttributionView()
                }
                .padding(.horizontal, Metrics.space4)
                .padding(.bottom, Metrics.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeFade()
        }
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
    }
}
