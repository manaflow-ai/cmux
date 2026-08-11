import SwiftUI

struct BrowserSurfaceView: View {
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
                        L10n.text("browser.remote_content", "Remote browser content"),
                        systemImage: "network"
                    )
                } description: {
                    Text(L10n.text(
                        "browser.manual_load",
                        "This tab does not load remote content until you open it."
                    ))
                } actions: {
                    Link(destination: url) {
                        Text(L10n.text("browser.open_external", "Open in Browser"))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("browser.invalid_url", "This browser tab has no valid URL."),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}
