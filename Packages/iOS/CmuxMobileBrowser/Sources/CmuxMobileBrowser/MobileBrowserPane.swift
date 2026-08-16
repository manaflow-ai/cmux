#if canImport(UIKit)
public import CMUXMobileCore
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
    private let onDiagnosticEvent: @MainActor (BrowserSurfaceDiagnosticEvent) -> Void
    private let presentationMode: MobileBrowserPresentationMode?
    private let onPresentationModeChange: ((MobileBrowserPresentationMode) -> Void)?

    /// Creates a browser pane.
    /// - Parameters:
    ///   - state: The browser surface state to host.
    ///   - onClose: Invoked when the user dismisses the pane.
    public init(
        state: BrowserSurfaceState,
        onClose: @escaping () -> Void,
        onDiagnosticEvent: @escaping @MainActor (BrowserSurfaceDiagnosticEvent) -> Void = { _ in },
        presentationMode: MobileBrowserPresentationMode? = nil,
        onPresentationModeChange: ((MobileBrowserPresentationMode) -> Void)? = nil
    ) {
        _state = State(initialValue: state)
        self.onClose = onClose
        self.onDiagnosticEvent = onDiagnosticEvent
        self.presentationMode = presentationMode
        self.onPresentationModeChange = onPresentationModeChange
    }

    public var body: some View {
        VStack(spacing: 0) {
            chromeBar
            if let presentationMode, let onPresentationModeChange {
                modePicker(mode: presentationMode, onChange: onPresentationModeChange)
            }
            progressLine
            ZStack {
                MobileBrowserView(state: state, onDiagnosticEvent: onDiagnosticEvent)
                if state.isFetchingFile {
                    fetchingOverlay
                } else if state.localFetchFailed {
                    localFetchErrorOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
    }

    private func modePicker(
        mode: MobileBrowserPresentationMode,
        onChange: @escaping (MobileBrowserPresentationMode) -> Void
    ) -> some View {
        Picker(
            L10n.string("mobile.browser.mode.label", defaultValue: "Browser mode"),
            selection: Binding(
                get: { mode },
                set: { onChange($0) }
            )
        ) {
            Text(L10n.string("mobile.browser.mode.stream", defaultValue: "Stream"))
                .tag(MobileBrowserPresentationMode.stream)
            Text(L10n.string("mobile.browser.mode.local", defaultValue: "Local"))
                .tag(MobileBrowserPresentationMode.local)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityIdentifier("MobileBrowserPresentationModePicker")
    }

    private var fetchingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView(value: state.localFetchProgress)
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text(L10n.string("mobile.browser.fetchingFile", defaultValue: "Fetching file…"))
                .font(.footnote.weight(.medium))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileBrowserFetchingFile")
    }

    private var localFetchErrorOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(L10n.string(
                "mobile.browser.localFetchFailed",
                defaultValue: "This file could not be fetched from the Mac."
            ))
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileBrowserLocalFetchError")
    }

    private var chromeBar: some View {
        HStack(spacing: 12) {
            Button {
                onDiagnosticEvent(.backRequested)
                state.request(.goBack)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!state.canGoBack)
            .accessibilityLabel(L10n.string("mobile.browser.back", defaultValue: "Back"))
            .accessibilityIdentifier("MobileBrowserBackButton")

            Button {
                onDiagnosticEvent(.forwardRequested)
                state.request(.goForward)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!state.canGoForward)
            .accessibilityLabel(L10n.string("mobile.browser.forward", defaultValue: "Forward"))
            .accessibilityIdentifier("MobileBrowserForwardButton")

            addressField

            reloadOrStopButton

            Button {
                onDiagnosticEvent(.closed)
                onClose()
            } label: {
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
                onDiagnosticEvent(.stopRequested)
                state.request(.stopLoading)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel(L10n.string("mobile.browser.stop", defaultValue: "Stop"))
            .accessibilityIdentifier("MobileBrowserStopButton")
        } else {
            Button {
                onDiagnosticEvent(.reloadRequested)
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
