#if os(iOS)
import SwiftUI

/// A Mac's browser tab opened on this iPhone: the phone's own web view, a small
/// button back to the Mac's mirrored page (it also tells the person the page is
/// not the Mac's), and why the page is empty when the phone can't show it.
struct NativeBrowserPage: View {
    let model: BrowserTabModel
    let macName: String
    var insets: EdgeInsets
    var isZoomGestureActive: Bool
    var reportScroll: @MainActor (CGFloat) -> Void
    /// Linked to the Mac: the page can go back to its mirror.
    var canMirror: Bool
    var mirror: @MainActor () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BrowserPage(model: model, insets: insets, isZoomGestureActive: isZoomGestureActive, reportScroll: reportScroll)
                .accessibilityIdentifier("browser.native")
            if let problem = model.problem {
                card(problem)
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
            } else if canMirror {
                // Where the mirrored page has its keyboard button.
                Button(action: mirror) {
                    Image(systemName: "macbook")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(12)
                .padding(.bottom, insets.bottom)
                .accessibilityLabel(Text("Mirror from \(macName)"))
                .accessibilityHint(Text("This page is open on this iPhone. Shows \(macName)'s page instead."))
                .accessibilityIdentifier("browser.mirror")
            }
        }
        // Another tab or the workspace list: the page's sound and video stop.
        .onDisappear { model.webView.pauseAllMediaPlayback() }
    }

    private func card(_ problem: BrowserTabModel.Problem) -> some View {
        let label = WorkspaceTabsSource.addressLabel(problem.url)
        return VStack(spacing: 12) {
            Image(systemName: problem.isMacOnly ? "macbook" : "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(Self.title(problem, label: label, macName: macName))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(Self.detail(problem, macName: macName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if !problem.isMacOnly, !problem.isInsecure {
                    Button("Try Again") { model.reloadOrStop() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("browser.native.retry")
                }
                if canMirror {
                    Button("Mirror from \(macName)", action: mirror)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("browser.native.mirror")
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.native.problem")
    }

    static func title(_ problem: BrowserTabModel.Problem, label: String, macName: String) -> String {
        if problem.isMacOnly { return String(localized: "\(label) is on \(macName)") }
        if problem.isInsecure { return String(localized: "This iPhone can't open \(label)") }
        return String(localized: "This iPhone can't reach \(label)")
    }

    static func detail(_ problem: BrowserTabModel.Problem, macName: String) -> String {
        // The Mac's own words ("Nothing is listening on port 3000 on this Mac."), named.
        if let detail = problem.detail {
            return detail.replacingOccurrences(of: "this Mac", with: macName).replacingOccurrences(of: "the Mac", with: macName)
        }
        if problem.isInsecure {
            return String(localized: "It isn't a secure (https) page, and iOS opens only secure pages in cmux. \(macName)'s mirrored page can show it.")
        }
        if problem.isMacOnly {
            return String(localized: "It runs on \(macName) itself, so only the mirrored page can show it.")
        }
        if problem.isPrivateNetwork {
            return String(localized: "It may only be reachable from \(macName)'s network, such as its local network or tailnet.")
        }
        return problem.message
    }
}
#endif
