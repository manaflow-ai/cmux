import SwiftUI

struct BrowserSurfaceView: View {
    @Environment(\.localization) private var localization
    let browser: BrowserSnapshot

    var body: some View {
        let isSecure = URL(string: browser.url)?.scheme?.lowercased() == "https"
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isSecure ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(browser.url)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if browser.loading {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)
            Divider()
            if let url = URL(string: browser.url),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            {
                ContentUnavailableView {
                    Label(
                        localization.text("browser.remote_content", "Remote browser content"),
                        systemImage: "network"
                    )
                } description: {
                    Text(localization.text(
                        "browser.manual_load",
                        "This tab does not load remote content until you open it."
                    ))
                } actions: {
                    Link(destination: url) {
                        Text(localization.text("browser.open_external", "Open in Browser"))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    localization.text("browser.invalid_url", "This browser tab has no valid URL."),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}
