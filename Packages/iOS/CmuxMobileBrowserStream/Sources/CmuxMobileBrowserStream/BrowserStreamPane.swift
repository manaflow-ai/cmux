#if canImport(UIKit)
public import SwiftUI
public import CmuxMobileSupport

/// Complete iOS chrome and interaction surface for one streamed Mac browser panel.
///
/// Chrome is a single always-visible bottom glass bar in the thumb zone:
/// back, forward, an editable address field, reload, and a keyboard toggle,
/// like a phone browser's bottom bar. It never collapses to a pill and has no
/// close affordance of its own; leaving the browser surface (via the workspace
/// surface picker or nav back) stops the stream from the parent. The bar lives
/// in a bottom `safeAreaInset` so it reserves its height (never occluding page
/// content) and rides up with the keyboard.
public struct BrowserStreamPane: View {
    @State private var state: BrowserStreamSurfaceState

    private let actions: BrowserStreamSurfaceActions
    private let reconnect: () -> Void
    private let modePicker: MobileBrowserModePicker?

    /// Creates a full browser streaming pane.
    /// - Parameters:
    ///   - state: Observable state for the selected Mac browser panel.
    ///   - actions: RPC actions for browser input and chrome.
    ///   - reconnect: Requests connection recovery for the selected Mac.
    ///   - modePicker: The Streamed / On iPhone switch, when offered.
    public init(
        state: BrowserStreamSurfaceState,
        actions: BrowserStreamSurfaceActions,
        reconnect: @escaping () -> Void,
        modePicker: MobileBrowserModePicker? = nil
    ) {
        _state = State(initialValue: state)
        self.actions = actions
        self.reconnect = reconnect
        self.modePicker = modePicker
    }

    /// Renders the mirrored frame surface, lifecycle overlays, and bottom chrome.
    public var body: some View {
        BrowserStreamSurfaceRepresentable(state: state, actions: actions)
            .accessibilityIdentifier("BrowserStreamSurface")
            .overlay { paneOverlay }
            .background(Color(red: 0.055, green: 0.063, blue: 0.075))
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    // MARK: - Bottom chrome

    /// The shared phone browser chrome (also used by the native in-app
    /// browser), with the keyboard toggle a pixel-streamed page needs.
    private var bottomBar: some View {
        MobileBrowserChromeBar(
            page: .init(
                url: state.url,
                canGoBack: state.canGoBack,
                canGoForward: state.canGoForward,
                isLoading: state.isLoading,
                progress: state.progress
            ),
            actions: .init(
                back: { state.request(.back) },
                forward: { state.request(.forward) },
                reload: { state.request(.reload) },
                submit: { address in
                    state.request(.navigate(address))
                    return true
                }
            ),
            keyboard: .init(
                show: { state.toggleManualKeyboard() },
                hide: { state.hideKeyboardForChrome() }
            ),
            modePicker: modePicker,
            identifiers: .init(prefix: "BrowserStream")
        )
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
        } else if state.isBlankPage {
            newPagePlaceholder
        } else if state.latestFrame == nil {
            statusOverlay(
                title: L10n.string("mobile.browserStream.waiting", defaultValue: "Waiting for Browser"),
                detail: L10n.string("mobile.browserStream.waitingDetail", defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "globe"
            )
            .accessibilityIdentifier("BrowserStreamPlaceholder")
        }
    }

    /// Deliberate empty state for a browser that has not opened a page yet.
    ///
    /// A fresh pane's mirror is an empty white capture, which looks like a
    /// glitch; this opaque placeholder replaces it until the first navigation.
    private var newPagePlaceholder: some View {
        ZStack {
            Color(red: 0.055, green: 0.063, blue: 0.075)
            VStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L10n.string("mobile.browserStream.newPage", defaultValue: "New Browser"))
                    .font(.headline)
                Text(L10n.string(
                    "mobile.browserStream.newPageDetail",
                    defaultValue: "Search or enter an address in the bar below."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .accessibilityIdentifier("BrowserStreamNewPagePlaceholder")
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
}
#endif
