import AppKit
import SwiftUI

/// SwiftUI host for ``CEFBrowserPanel``. The parallel to
/// ``BrowserPanelView`` for the experimental CEF engine.
///
/// v1 scope: render the CEF browser's content NSView inside the cmux
/// pane area with a minimal browser toolbar, close to the existing
/// WKWebView chrome. Find / popup UI come in follow-up PRs. The pane
/// background and any cmux pane chrome live in the surrounding view
/// tree (same as ``BrowserPanelView``).
struct CEFBrowserPanelView: View {
    let panel: CEFBrowserPanel
    let paneId: Any
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var cefRuntimeInstaller = CEFRuntimeInstaller.shared
    @State private var activationError: Error?
    @State private var addressText: String = ""
    @State private var addressFieldFocused: Bool = false
    @State private var addressSelectAllRequestId: UInt64 = 0

    private var activationTaskID: CEFBrowserPanelActivationTaskID {
        CEFBrowserPanelActivationTaskID(
            isVisibleInUI: isVisibleInUI,
            runtimeReady: cefRuntimeInstaller.phase == .installed
                || cefRuntimeInstaller.isInstalledOrBundled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            ZStack {
                if let error = activationError {
                    fallbackView(for: error)
                } else {
                    CEFContentRepresentable(
                        panel: panel,
                        revision: panel.activationRevision,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: activationTaskID) {
            if addressText.isEmpty {
                addressText = panel.addressBarDisplayString
            }
            guard isVisibleInUI else { return }
            do {
                try await panel.activate(presentingWindow: NSApp.keyWindow ?? NSApp.mainWindow)
                activationError = nil
            } catch {
                activationError = error
                #if DEBUG
                cmuxDebugLog("cef.panel.view.activate.failed panel=\(panel.id.uuidString.prefix(5)) error=\(String(describing: error))")
                #endif
            }
        }
        .onChange(of: panel.currentURL) { _, newURL in
            guard !addressFieldFocused else { return }
            addressText = newURL?.absoluteString ?? panel.addressBarDisplayString
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            browserToolbarButton(
                systemImage: "chevron.left",
                help: String(localized: "cefBrowserPanel.back", defaultValue: "Back"),
                isEnabled: panel.canGoBack,
                action: panel.goBack)

            browserToolbarButton(
                systemImage: "chevron.right",
                help: String(localized: "cefBrowserPanel.forward", defaultValue: "Forward"),
                isEnabled: panel.canGoForward,
                action: panel.goForward)

            browserToolbarButton(
                systemImage: panel.isLoading ? "xmark" : "arrow.clockwise",
                help: panel.isLoading
                    ? String(localized: "cefBrowserPanel.stop", defaultValue: "Stop loading")
                    : String(localized: "cefBrowserPanel.reload", defaultValue: "Reload"),
                action: {
                    if panel.isLoading {
                        panel.stopLoading()
                    } else {
                        panel.reload()
                    }
                })

            addressPill

            browserToolbarButton(
                systemImage: "antenna.radiowaves.left.and.right",
                help: String(localized: "cefBrowserPanel.remoteDebugStatus", defaultValue: "Remote debugging"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "person.circle",
                help: String(localized: "cefBrowserPanel.profile", defaultValue: "Profile"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "circle.lefthalf.filled",
                help: String(localized: "cefBrowserPanel.appearance", defaultValue: "Appearance"),
                action: {})
            .disabled(true)

            browserToolbarButton(
                systemImage: "wrench.and.screwdriver",
                help: String(localized: "cefBrowserPanel.devTools", defaultValue: "DevTools"),
                action: panel.showDevTools)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)
        }
    }

    private var addressPill: some View {
        HStack(spacing: 6) {
            Image(systemName: isSecureURL ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            OmnibarTextFieldRepresentable(
                panelId: panel.id,
                text: $addressText,
                isFocused: $addressFieldFocused,
                selectAllRequestId: addressSelectAllRequestId,
                inlineCompletion: nil,
                placeholder: String(
                    localized: "cefBrowserPanel.addressPlaceholder",
                    defaultValue: "Search or enter address"),
                onTap: {
                    if !addressFieldFocused {
                        addressSelectAllRequestId &+= 1
                    }
                    addressFieldFocused = true
                },
                onSubmit: commitAddressBar,
                onEscape: {
                    addressText = panel.currentURL?.absoluteString ?? panel.addressBarDisplayString
                    addressFieldFocused = false
                },
                onFieldLostFocus: {
                    addressFieldFocused = false
                },
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: {},
                onClearTypedPrefixWithInlineSelection: {},
                onDeleteWordBackwardWithInlineSelection: {},
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { addressFieldFocused }
            )
            .frame(height: 20)
            .onChange(of: addressFieldFocused) { _, isFocused in
                if isFocused {
                    addressText = panel.addressBarDisplayString
                } else {
                    addressText = panel.currentURL?.absoluteString ?? panel.addressBarDisplayString
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.38))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private var isSecureURL: Bool {
        let raw = addressFieldFocused ? addressText : panel.addressBarDisplayString
        return URL(string: raw)?.scheme == "https"
    }

    @ViewBuilder
    private func browserToolbarButton(
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(CEFBrowserToolbarButtonStyle())
        .disabled(!isEnabled)
        .help(help)
    }

    private func commitAddressBar() {
        guard let url = normalizedURL(from: addressText) else {
            addressText = panel.currentURL?.absoluteString ?? panel.addressBarDisplayString
            return
        }
        addressText = url.absoluteString
        panel.load(url)
    }

    private func normalizedURL(from text: String) -> URL? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if let url = URL(string: raw), url.scheme != nil {
            return url
        }

        if raw.contains("."),
           !raw.contains(" "),
           let url = URL(string: "https://\(raw)")
        {
            return url
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: raw)]
        return components.url
    }

    @ViewBuilder
    private func fallbackView(for error: Error) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text(activationFailureMessage(for: error))
                .font(.callout)
                .multilineTextAlignment(.center)
            Text(String(
                localized: "cefBrowserPanel.fallbackHint",
                defaultValue: "Switch back to WKWebView from Debug → Browser Engine."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activationFailureMessage(for error: Error) -> String {
        if let panelError = error as? CEFBrowserPanelError {
            return panelError.localizedDescription
        }
        return String(
            localized: "cefBrowserPanel.activationFailed.message",
            defaultValue: "Chromium could not start for this pane."
        )
    }
}

private struct CEFBrowserToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                        : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

private struct CEFBrowserPanelActivationTaskID: Equatable {
    let isVisibleInUI: Bool
    let runtimeReady: Bool
}
