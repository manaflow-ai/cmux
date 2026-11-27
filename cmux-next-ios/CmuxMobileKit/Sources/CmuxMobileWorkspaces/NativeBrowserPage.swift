#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Observation
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
    /// A page the phone couldn't reach is loaded again on its own (no button: reloading a
    /// page that never arrived has only one answer); the card says so past the quiet bound.
    @State private var autoRetry = AutoRetry()
    /// The card a retry is answering, kept on screen while the page loads again (the load
    /// clears `model.problem`), so the card does not blink away and back.
    @State private var retrying: BrowserTabModel.Problem?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BrowserPage(model: model, insets: insets, isZoomGestureActive: isZoomGestureActive, reportScroll: reportScroll)
                .accessibilityIdentifier("browser.native")
            if let problem = model.problem ?? retrying {
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
                .buttonStyle(.cmuxPressGlass)
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
        .autoRetry(autoRetry, failing: model.problem.map(Self.retries) ?? false || retrying != nil) { await retry() }
    }

    /// Only a page the phone could not reach is loaded again; a Mac-only or insecure page
    /// would fail the same way every time.
    static func retries(_ problem: BrowserTabModel.Problem) -> Bool {
        !problem.isMacOnly && !problem.isInsecure
    }

    /// Loads the failed address again and returns once it answered (loaded, or failed again).
    private func retry() async {
        guard let problem = model.problem ?? retrying, Self.retries(problem), !model.isLoading else { return }
        retrying = problem
        defer { retrying = nil }
        model.reloadOrStop()
        let model = model
        // The load starts at once (or fails at once), then answers within WebKit's own timeout.
        await BoundedWait(.seconds(2)).run { @MainActor in await Self.until(model) { $0.isLoading || $0.problem != nil } }
        await BoundedWait(.seconds(60)).run { @MainActor in await Self.until(model) { !$0.isLoading || $0.problem != nil } }
    }

    /// Waits until `done` reads true (Observation wakes it; no polling); cancelling it ends it.
    private static func until(_ model: BrowserTabModel, _ done: @escaping @MainActor (BrowserTabModel) -> Bool) async {
        await BoundedWait.observing { !done(model) }
    }

    private func card(_ problem: BrowserTabModel.Problem) -> some View {
        let label = WorkspaceTabsSource.addressLabel(problem.url)
        return VStack(spacing: 12) {
            Image(systemName: problem.isMacOnly ? "macbook" : "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.title(problem, label: label, macName: macName))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(Self.detail(problem, macName: macName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if Self.retries(problem) {
                AutoRetryQuietLine(autoRetry)
            }
            HStack(spacing: 10) {
                if canMirror {
                    Button("Mirror from \(macName)", action: mirror)
                        .buttonStyle(.glassProminent)
                        // One plain element framed by layout: the prominent glass
                        // style's own reported an unconverted frame in the iPhone
                        // app's scaled window on iPad (as Welcome's sign-in row).
                        .accessibilityRepresentation { Button("Mirror from \(macName)", action: mirror) }
                        .accessibilityIdentifier("browser.native.mirror")
                }
            }
            // Both actions are capsules of one height, whatever the title length.
            .buttonBorderShape(.capsule)
            .controlSize(.large)
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
