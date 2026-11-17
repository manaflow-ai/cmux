#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// ask-87d30da8e5: the chrome under a Mac's theme, for screenshots. Launch with
/// `-cmux-mobile-recovery-gallery theme-mocha|theme-solarized|theme-wallpaper`: a dark theme, a
/// light one with the Mac's blue accent, and the dark one naming a wallpaper. Each applies its
/// fixture as a Mac's frame would (and so writes the simulator's cache). The backgrounds stay the
/// stock ones and no picture shows; only the accent takes the Mac's.
struct MacThemeGallery: View {
    let variant: String
    private let theme = CmuxMobileTheme.standard

    static let mocha = CmuxMobileMacAppearance(theme: .init(
        background: "#1e1e2e", foreground: "#cdd6f4",
        palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                  "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]))
    static let solarized = CmuxMobileMacAppearance(theme: .init(
        background: "#fdf6e3", foreground: "#657b83",
        palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5"],
        accent: "blue"))

    init(variant: String) {
        self.variant = variant
        var appearance = variant == "theme-solarized" ? Self.solarized : Self.mocha
        if variant == "theme-wallpaper" {
            appearance.wallpaper = .init(id: "9a11e7", bytes: 48_000, tintOpacity: 0.55)
        }
        CmuxMobileMacTheme.shared.matchesMac = true
        CmuxMobileMacTheme.shared.apply(appearance)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Chief", detail: "Merged the sidebar fix. Want me to start the next one?", unread: true)
                    row("cmux", detail: "Claude: Tests pass on the fleet.", unread: false)
                    row("website", detail: "Codex: Waiting for your answer", unread: false)
                }
                .listRowBackground(theme.colors.bg.color)
                Section {
                    HStack {
                        Text("Send")
                            .font(theme.type.rowTitle)
                            .foregroundStyle(theme.colors.onAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(theme.colors.accent, in: .rect(cornerRadius: 10, style: .continuous))
                        Spacer()
                        Text("Needs you").foregroundStyle(theme.colors.warning)
                        Text("Failed").foregroundStyle(theme.colors.danger)
                        Text("Done").foregroundStyle(theme.colors.success)
                    }
                    .padding(12)
                    .background(theme.colors.surface, in: .rect(cornerRadius: 12, style: .continuous))
                }
                .listRowBackground(theme.colors.bg.color)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle("Home")
        }
    }

    private func row(_ title: String, detail: String, unread: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(theme.colors.accent)
                .frame(width: 8, height: 8)
                .opacity(unread ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                Text(verbatim: detail).font(.subheadline).foregroundStyle(theme.colors.label2).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
