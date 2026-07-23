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

    /// Opens the current page in Safari when requested from the overflow menu.
    @Environment(\.openURL) private var openURL

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

            overflowMenu

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
        HStack(spacing: 6) {
            securityIndicator

            TextField(
                L10n.string("mobile.browser.addressPlaceholder", defaultValue: "Search or enter address"),
                text: $state.addressText
            )
            .textFieldStyle(.plain)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var securityIndicator: some View {
        switch BrowserSecurityIndicator(url: state.currentURL) {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("mobile.browser.security.secure", defaultValue: "Secure connection"))
                .accessibilityIdentifier("MobileBrowserSecureIndicator")
        case .insecure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel(L10n.string("mobile.browser.security.insecure", defaultValue: "Not secure"))
                .accessibilityIdentifier("MobileBrowserInsecureIndicator")
        case .none:
            EmptyView()
        }
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

    private var overflowMenu: some View {
        Menu {
            shareMenuItem

            Button {
                if let url = state.currentURL {
                    openURL(url)
                }
            } label: {
                menuLabel(
                    L10n.string("mobile.browser.openInSafari", defaultValue: "Open in Safari"),
                    systemImage: "safari"
                )
            }
            .disabled(state.currentURL == nil)

            Button {
                state.togglePrefersDesktopSite()
            } label: {
                menuLabel(
                    state.prefersDesktopSite
                        ? L10n.string("mobile.browser.requestMobileSite", defaultValue: "Request Mobile Site")
                        : L10n.string("mobile.browser.requestDesktopSite", defaultValue: "Request Desktop Site"),
                    systemImage: state.prefersDesktopSite ? "iphone" : "desktopcomputer"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(L10n.string("mobile.browser.more", defaultValue: "More"))
        .accessibilityIdentifier("MobileBrowserOverflowMenu")
    }

    @ViewBuilder
    private var shareMenuItem: some View {
        if let url = state.currentURL {
            ShareLink(item: url) {
                menuLabel(
                    L10n.string("mobile.browser.share", defaultValue: "Share"),
                    systemImage: "square.and.arrow.up"
                )
            }
        } else {
            Button {} label: {
                menuLabel(
                    L10n.string("mobile.browser.share", defaultValue: "Share"),
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(true)
        }
    }

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
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
