#if canImport(UIKit)
public import SwiftUI
public import CmuxMobileSupport

/// A complete phone browser pane: a hosted `WKWebView` with the same bottom
/// glass chrome the streamed browser uses (``MobileBrowserChromeBar``: back,
/// forward, address, reload or stop, and a load progress line).
///
/// This is the browser sibling of the terminal surface view. It is driven
/// entirely by an `@Observable` ``BrowserSurfaceState``: the chrome reads the
/// state's flags and writes navigation commands back into it, and
/// ``MobileBrowserView`` carries those into the web view. Like the streamed
/// browser it has no close button: choosing another surface in the workspace
/// picker leaves it.
public struct MobileBrowserPane: View {
    /// The browser surface state this pane drives and reflects.
    @State private var state: BrowserSurfaceState

    private let serverRoute: BrowserServerRoute?
    private let modePicker: MobileBrowserModePicker?
    private let addressIdentifier: String?
    private let onDiagnosticEvent: @MainActor (BrowserSurfaceDiagnosticEvent) -> Void

    /// Creates a browser pane.
    /// - Parameters:
    ///   - state: The browser surface state to host.
    ///   - serverRoute: In an SSH workspace, browses through that computer
    ///     (``BrowserServerRoute``), so `localhost:3000` is the computer's.
    ///   - modePicker: The Streamed / On iPhone switch, when offered.
    ///   - addressIdentifier: Accessibility identifier for the address
    ///     field; defaults to `MobileBrowserAddressField`.
    public init(
        state: BrowserSurfaceState,
        serverRoute: BrowserServerRoute? = nil,
        modePicker: MobileBrowserModePicker? = nil,
        addressIdentifier: String? = nil,
        onDiagnosticEvent: @escaping @MainActor (BrowserSurfaceDiagnosticEvent) -> Void = { _ in }
    ) {
        _state = State(initialValue: state)
        self.serverRoute = serverRoute
        self.modePicker = modePicker
        self.addressIdentifier = addressIdentifier
        self.onDiagnosticEvent = onDiagnosticEvent
    }

    public var body: some View {
        MobileBrowserView(state: state, serverRoute: serverRoute, onDiagnosticEvent: onDiagnosticEvent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { failureOverlay }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { chromeBar }
    }

    private var chromeBar: some View {
        MobileBrowserChromeBar(
            page: .init(
                url: state.addressText.isEmpty ? nil : state.addressText,
                canGoBack: state.canGoBack,
                canGoForward: state.canGoForward,
                isLoading: state.isLoading,
                progress: state.estimatedProgress
            ),
            actions: .init(
                back: {
                    onDiagnosticEvent(.backRequested)
                    state.request(.goBack)
                },
                forward: {
                    onDiagnosticEvent(.forwardRequested)
                    state.request(.goForward)
                },
                reload: {
                    onDiagnosticEvent(.reloadRequested)
                    reload()
                },
                stop: {
                    onDiagnosticEvent(.stopRequested)
                    state.request(.stopLoading)
                },
                submit: { address in
                    state.addressText = address
                    return state.submitAddress()
                },
                editingChanged: { editing in
                    // Keeps the web view's URL observer from overwriting
                    // in-progress typing (see `isAddressEditing`).
                    state.isAddressEditing = editing
                }
            ),
            modePicker: modePicker,
            identifiers: .init(prefix: "MobileBrowser", address: addressIdentifier)
        )
    }

    /// Replaces a blank web view when an address failed before any page
    /// from it showed (for example, nothing listens on that server port).
    @ViewBuilder
    private var failureOverlay: some View {
        if let failedURL = state.failedURL, !state.isLoading {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.browser.error.title", defaultValue: "Can't Open Page"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(state.lastErrorMessage ?? "")
            } actions: {
                Button(L10n.string("mobile.browser.error.retry", defaultValue: "Try Again")) {
                    state.load(failedURL)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("MobileBrowserRetryButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("MobileBrowserFailure")
        }
    }

    /// Reload retries a failed address; otherwise it reloads the page.
    private func reload() {
        if let failedURL = state.failedURL {
            state.load(failedURL)
        } else {
            state.request(.reload)
        }
    }
}
#endif
