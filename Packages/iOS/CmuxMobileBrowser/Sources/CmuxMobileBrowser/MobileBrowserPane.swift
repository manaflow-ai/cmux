#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport

/// A complete phone browser pane: a navigation chrome bar (back / forward /
/// reload / address field) over a hosted `WKWebView`, plus a determinate
/// loading line.
///
/// This is the browser sibling of the terminal surface view. It is driven
/// entirely by an `@Observable` ``BrowserSurfaceState``: the chrome reads the
/// state's flags and writes navigation commands back into it, and
/// ``MobileBrowserView`` carries those into the web view. A close action
/// returns the workspace to its terminal.
public struct MobileBrowserPane: View {
    /// The browser surface state this pane drives and reflects.
    @State private var state: BrowserSurfaceState

    /// Whether the address field currently has editing focus. While editing,
    /// the field shows the user's in-progress text rather than the live URL.
    @FocusState private var isAddressFocused: Bool

    /// Invoked when the user closes the browser pane.
    private let onClose: () -> Void

    /// Creates a browser pane.
    /// - Parameters:
    ///   - state: The browser surface state to host.
    ///   - onClose: Invoked when the user dismisses the pane.
    public init(state: BrowserSurfaceState, onClose: @escaping () -> Void) {
        _state = State(initialValue: state)
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            chromeBar
            progressLine
            MobileBrowserView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
    }

    private var chromeBar: some View {
        HStack(spacing: 12) {
            Button {
                state.request(.goBack)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!state.canGoBack)
            .accessibilityLabel(L10n.string("mobile.browser.back", defaultValue: "Back"))
            .accessibilityIdentifier("MobileBrowserBackButton")

            Button {
                state.request(.goForward)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!state.canGoForward)
            .accessibilityLabel(L10n.string("mobile.browser.forward", defaultValue: "Forward"))
            .accessibilityIdentifier("MobileBrowserForwardButton")

            addressField

            reloadOrStopButton

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(L10n.string("mobile.browser.close", defaultValue: "Close Browser"))
            .accessibilityIdentifier("MobileBrowserCloseButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var addressField: some View {
        TextField(
            L10n.string("mobile.browser.addressPlaceholder", defaultValue: "Search or enter address"),
            text: $state.addressText
        )
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .keyboardType(.webSearch)
        .submitLabel(.go)
        .focused($isAddressFocused)
        .onChange(of: isAddressFocused) { _, focused in
            // Mirror editing focus into the state so the web view's URL observer
            // does not overwrite in-progress typing (see `isAddressEditing`).
            state.isAddressEditing = focused
        }
        .onSubmit {
            if state.submitAddress() {
                isAddressFocused = false
            }
        }
        .accessibilityIdentifier("MobileBrowserAddressField")
    }

    @ViewBuilder
    private var reloadOrStopButton: some View {
        if state.isLoading {
            Button {
                state.request(.stopLoading)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel(L10n.string("mobile.browser.stop", defaultValue: "Stop"))
            .accessibilityIdentifier("MobileBrowserStopButton")
        } else {
            Button {
                state.request(.reload)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(L10n.string("mobile.browser.reload", defaultValue: "Reload"))
            .accessibilityIdentifier("MobileBrowserReloadButton")
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if state.isLoading {
            ProgressView(value: state.estimatedProgress)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .accessibilityIdentifier("MobileBrowserProgress")
        } else {
            Color.clear.frame(height: 2)
        }
    }
}
#endif
