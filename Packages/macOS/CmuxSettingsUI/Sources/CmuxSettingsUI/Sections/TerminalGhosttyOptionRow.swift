import CmuxFoundation
import SwiftUI

/// A Settings > Terminal row for one Ghostty option, captioned with its config
/// key (and `detail`, when given), with an override note beneath it when a
/// later-loading config file beats the value cmux wrote.
struct TerminalGhosttyOptionRow<Control: View>: View {
    let id: String
    let title: String
    let key: GhosttyTerminalOptionKey
    var detail: String?
    var controlWidth: CGFloat?
    let overriddenBy: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:terminal:\(id)",
                title,
                subtitle: [key.rawValue, detail].compactMap { $0 }.joined(separator: " · "),
                controlWidth: controlWidth,
                trailing: control
            )
            if let overriddenBy {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.ghostty.overridden",
                        defaultValue: "Overridden by your config (%@)"
                    ),
                    overriddenBy
                ))
                .cmuxFont(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
