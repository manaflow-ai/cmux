#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport

/// Complete iOS chrome and interaction surface for one streamed Mac browser panel.
public struct BrowserStreamPane: View {
    @State private var state: BrowserStreamSurfaceState
    @State private var addressText: String
    @State private var isEditingAddress = false
    @FocusState private var addressFocused: Bool

    private let frames: AsyncStream<BrowserStreamFrame>
    private let actions: BrowserStreamSurfaceActions
    private let didDisplay: @MainActor (BrowserStreamFrame) -> Void
    private let close: () -> Void
    private let reconnect: () -> Void

    /// Creates a full browser streaming pane.
    /// - Parameters:
    ///   - state: Observable state for the selected Mac browser panel.
    ///   - frames: Decoded frames for the current subscription.
    ///   - actions: RPC actions for browser input and chrome.
    ///   - didDisplay: Called after a frame is installed into the display layer.
    ///   - close: Closes the current streamed surface.
    ///   - reconnect: Requests connection recovery for the selected Mac.
    public init(
        state: BrowserStreamSurfaceState,
        frames: AsyncStream<BrowserStreamFrame>,
        actions: BrowserStreamSurfaceActions,
        didDisplay: @escaping @MainActor (BrowserStreamFrame) -> Void,
        close: @escaping () -> Void,
        reconnect: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        _addressText = State(initialValue: state.url ?? "")
        self.frames = frames
        self.actions = actions
        self.didDisplay = didDisplay
        self.close = close
        self.reconnect = reconnect
    }

    /// Renders browser chrome, the mirrored frame surface, and lifecycle overlays.
    public var body: some View {
        VStack(spacing: 0) {
            chrome
            progress
            BrowserStreamSurfaceRepresentable(
                state: state,
                frames: frames,
                actions: actions,
                didDisplay: didDisplay
            )
            .accessibilityIdentifier("BrowserStreamSurface")
            .overlay { surfaceOverlay }
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.075))
        .onChange(of: state.url) { _, url in
            if !isEditingAddress { addressText = url ?? "" }
        }
    }

    private var chrome: some View {
        HStack(spacing: 9) {
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

            addressPill

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var addressPill: some View {
        Group {
            if isEditingAddress {
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
            } else {
                Button {
                    isEditingAddress = true
                    addressFocused = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title ?? L10n.string("mobile.browserStream.untitled", defaultValue: "Browser"))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(state.url ?? L10n.string("mobile.browserStream.noAddress", defaultValue: "No address"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .mobileGlassPill()
        .accessibilityIdentifier("BrowserStreamAddressPill")
    }

    @ViewBuilder
    private var progress: some View {
        if state.isLoading {
            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .accessibilityLabel(L10n.string("mobile.browserStream.loading", defaultValue: "Loading"))
                .accessibilityIdentifier("BrowserStreamProgress")
        } else {
            Color.clear.frame(height: 2)
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
        isEditingAddress = false
        addressFocused = false
    }
}
#endif
