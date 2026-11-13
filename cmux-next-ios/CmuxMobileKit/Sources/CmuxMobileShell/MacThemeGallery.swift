#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// ask-87d30da8e5: the chrome under a Mac's theme, for screenshots. Launch with
/// `-cmux-mobile-recovery-gallery theme-mocha|theme-solarized|theme-wallpaper`: a dark theme, a
/// light one with the Mac's blue accent, and the dark one with a wallpaper under its tint. Each
/// applies its fixture as a Mac's frame would (and so writes the simulator's cache).
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

    /// A warm-to-cool gradient standing in for a wallpaper.
    static func picture() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 1200)).jpegData(withCompressionQuality: 0.9) { context in
            let colors = [UIColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1).cgColor,
                          UIColor(red: 0.25, green: 0.35, blue: 0.75, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 1200), options: [])
            }
        }
    }

    init(variant: String) {
        self.variant = variant
        var appearance = variant == "theme-solarized" ? Self.solarized : Self.mocha
        var bytes: Data?
        if variant == "theme-wallpaper" {
            let data = Self.picture()
            appearance.wallpaper = .init(id: "9a11e7", bytes: data.count, tintOpacity: 0.55)
            bytes = data
        }
        CmuxMobileMacTheme.shared.matchesMac = true
        CmuxMobileMacTheme.shared.apply(appearance, wallpaper: bytes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Chief", detail: "Merged the sidebar fix. Want me to start the next one?", unread: true)
                    row("cmux", detail: "Claude: Tests pass on the fleet.", unread: false)
                    row("website", detail: "Codex: Waiting for your answer", unread: false)
                }
                .listRowBackground(CmuxMobileBackdrop.listRow)
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
                .listRowBackground(CmuxMobileBackdrop.listRow)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CmuxMobileBackdrop().ignoresSafeArea())
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
