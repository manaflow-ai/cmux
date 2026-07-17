#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport

/// Complete iOS chrome and interaction surface for one streamed Mac browser panel.
///
/// The mirrored page fills the pane edge to edge; chrome is a floating bottom
/// glass bar in the thumb zone. Collapsed, it is a compact pill showing the
/// page's host and load progress. Tapping it expands the full controls
/// (back/forward, editable address, reload, keyboard, close); submitting or
/// tapping the collapse chevron returns to the pill.
public struct BrowserStreamPane: View {
    @State private var state: BrowserStreamSurfaceState
    @State private var addressText: String
    @State private var isBarExpanded = false
    @FocusState private var addressFocused: Bool

    private let actions: BrowserStreamSurfaceActions
    private let close: () -> Void
    private let reconnect: () -> Void

    /// Creates a full browser streaming pane.
    /// - Parameters:
    ///   - state: Observable state for the selected Mac browser panel.
    ///   - actions: RPC actions for browser input and chrome.
    ///   - close: Closes the current streamed surface.
    ///   - reconnect: Requests connection recovery for the selected Mac.
    public init(
        state: BrowserStreamSurfaceState,
        actions: BrowserStreamSurfaceActions,
        close: @escaping () -> Void,
        reconnect: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        _addressText = State(initialValue: state.url ?? "")
        self.actions = actions
        self.close = close
        self.reconnect = reconnect
    }

    /// Renders the mirrored frame surface, lifecycle overlays, and bottom chrome.
    ///
    /// The bar lives in a bottom `safeAreaInset`, which reserves its height so
    /// the mirror ends above it. The chrome must never occlude live page
    /// content: an earlier full-bleed version let the pill float over the
    /// bottom strip of the page, hiding it. The inset also rides up with the
    /// keyboard.
    public var body: some View {
        BrowserStreamSurfaceRepresentable(state: state, actions: actions)
            .accessibilityIdentifier("BrowserStreamSurface")
            .overlay { paneOverlay }
            .background(Color(red: 0.055, green: 0.063, blue: 0.075))
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .onChange(of: state.url) { _, url in
                if !addressFocused { addressText = url ?? "" }
            }
    }

    // MARK: - Bottom chrome

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if isBarExpanded {
                expandedBar
            } else {
                collapsedPill
            }
        }
        .padding(.horizontal, isBarExpanded ? 12 : 60)
        .padding(.bottom, 10)
        .animation(.spring(duration: 0.32, bounce: 0.24), value: isBarExpanded)
    }

    private var collapsedPill: some View {
        Button {
            isBarExpanded = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSecure ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(displayHost)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .mobileGlassPill()
        .overlay(alignment: .bottom) { pillProgress }
        .clipShape(Capsule())
        .accessibilityLabel(L10n.string("mobile.browserStream.showControls", defaultValue: "Show Browser Controls"))
        .accessibilityIdentifier("BrowserStreamAddressPill")
    }

    private var expandedBar: some View {
        HStack(spacing: 10) {
            chromeButton(
                systemImage: "chevron.backward",
                label: L10n.string("mobile.browserStream.back", defaultValue: "Back"),
                identifier: "BrowserStreamBackButton",
                disabled: !state.canGoBack
            ) { state.request(.back) }
            chromeButton(
                systemImage: "chevron.forward",
                label: L10n.string("mobile.browserStream.forward", defaultValue: "Forward"),
                identifier: "BrowserStreamForwardButton",
                disabled: !state.canGoForward
            ) { state.request(.forward) }

            TextField(
                L10n.string("mobile.browserStream.addressPlaceholder", defaultValue: "Search or enter address"),
                text: $addressText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .focused($addressFocused)
            .onSubmit { submitAddress() }
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .accessibilityIdentifier("BrowserStreamAddressField")

            chromeButton(
                systemImage: "arrow.clockwise",
                label: L10n.string("mobile.browserStream.reload", defaultValue: "Reload"),
                identifier: "BrowserStreamReloadButton"
            ) { state.request(.reload) }
            chromeButton(
                systemImage: state.shouldFocusInput ? "keyboard.chevron.compact.down" : "keyboard",
                label: state.shouldFocusInput
                    ? L10n.string("mobile.browserStream.hideKeyboard", defaultValue: "Hide Keyboard")
                    : L10n.string("mobile.browserStream.keyboard", defaultValue: "Show Keyboard"),
                identifier: "BrowserStreamKeyboardButton"
            ) { state.toggleManualKeyboard() }
            chromeButton(
                systemImage: "xmark",
                label: L10n.string("mobile.browserStream.close", defaultValue: "Close Stream"),
                identifier: "BrowserStreamCloseButton",
                action: close
            )
            chromeButton(
                systemImage: "chevron.down",
                label: L10n.string("mobile.browserStream.hideControls", defaultValue: "Hide Browser Controls"),
                identifier: "BrowserStreamCollapseButton"
            ) { collapseBar() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .mobileGlassPill()
        .overlay(alignment: .bottom) { pillProgress }
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var pillProgress: some View {
        if state.isLoading {
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .padding(.horizontal, 18)
                .accessibilityLabel(L10n.string("mobile.browserStream.loading", defaultValue: "Loading"))
                .accessibilityIdentifier("BrowserStreamProgress")
        }
    }

    private var isSecure: Bool {
        state.url?.hasPrefix("https://") == true
    }

    private var displayHost: String {
        if let url = state.url.flatMap(URL.init(string:)), let host = url.host() {
            return host
        }
        return state.title ?? L10n.string("mobile.browserStream.untitled", defaultValue: "Browser")
    }

    private func collapseBar() {
        addressFocused = false
        isBarExpanded = false
    }

    // MARK: - Overlays

    @ViewBuilder
    private var paneOverlay: some View {
        ZStack {
            surfaceOverlay
            if let dialog = state.pendingDialog {
                BrowserStreamDialogCard(dialog: dialog) { response in
                    Task { await actions.respondToDialog(response) }
                }
                .id(dialog.dialogID)
            }
        }
    }

    @ViewBuilder
    private var surfaceOverlay: some View {
        if state.connectionStatus != .connected {
            disconnectedOverlay
        } else if state.streamStatus == .paused {
            statusOverlay(
                title: L10n.string("mobile.browserStream.paused", defaultValue: "Stream Paused"),
                detail: L10n.string("mobile.browserStream.pausedDetail", defaultValue: "Return to cmux to resume the browser mirror."),
                symbol: "pause.circle"
            )
            .accessibilityIdentifier("BrowserStreamPausedOverlay")
        } else if state.latestFrame == nil {
            statusOverlay(
                title: L10n.string("mobile.browserStream.waiting", defaultValue: "Waiting for Browser"),
                detail: L10n.string("mobile.browserStream.waitingDetail", defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "globe"
            )
            .accessibilityIdentifier("BrowserStreamPlaceholder")
        }
    }

    private var disconnectedOverlay: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 14) {
                if state.connectionStatus == .reconnecting {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "wifi.slash").font(.system(size: 38))
                }
                Text(
                    state.connectionStatus == .reconnecting
                        ? L10n.string("mobile.connection.reconnecting", defaultValue: "Reconnecting")
                        : L10n.string("mobile.browserStream.disconnected", defaultValue: "Browser Disconnected")
                )
                    .font(.headline)
                Text(
                    state.connectionStatus == .reconnecting
                        ? L10n.string("mobile.connection.reconnectingDescription", defaultValue: "Trying to reach the selected cmux build.")
                        : L10n.string("mobile.browserStream.disconnectedDetail", defaultValue: "Reconnect to the Mac to continue streaming.")
                )
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                if state.connectionStatus == .disconnected {
                    Button(action: reconnect) {
                        Label(
                            L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("BrowserStreamReconnectButton")
                }
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .accessibilityIdentifier("BrowserStreamDisconnectedOverlay")
    }

    private func statusOverlay(title: String, detail: String, symbol: String) -> some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 36))
                Text(title).font(.headline)
                Text(detail).font(.subheadline).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
    }

    private func chromeButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: systemImage).frame(width: 24, height: 24) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.request(.navigate(trimmed))
        collapseBar()
    }
}
#endif
