#if canImport(UIKit)
import CmuxMobileShell
import CmuxMobileSimulatorStream
import CmuxMobileSupport
import CmuxSimulatorStreamKit
import SwiftUI
import UIKit

/// Simulator streaming v2: hardware-decoded video over a dedicated lane.
///
/// The pane owns its whole session: appear attaches, disappear detaches, and
/// every recovery path is the store's single reattach flow. There is no
/// shared stream state anywhere else in the shell, which is what makes a
/// remount or route change unable to strand a session.
struct SimulatorStreamV2Pane: View {
    let panelID: String
    let access: SimulatorStreamV2Access
    let isTransportReady: Bool

    @State private var store: SimulatorStreamV2Store?
    @State private var pendingText = ""
    @FocusState private var textFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let store {
                    SimStreamDisplayRepresentable(store: store)
                        .accessibilityIdentifier("SimulatorStreamV2Video")
                    overlay(for: store.phase)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .accessibilityIdentifier("SimulatorStreamV2Pane")
        .onAppear {
            let store =
                self.store
                ?? SimulatorStreamV2Store(
                    panelID: panelID,
                    opener: access.opener,
                    transportReady: access.transportReady
                )
            self.store = store
            store.activate()
        }
        .onDisappear {
            store?.deactivate()
        }
        .onChange(of: isTransportReady) { _, ready in
            store?.noteTransportReady(ready)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store?.appBackgrounded()
            case .active:
                store?.appForegrounded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func overlay(for phase: SimStreamViewerPhase) -> some View {
        switch phase {
        case .idle, .connecting:
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.waiting", defaultValue: "Waiting for Simulator"),
                detail: L10n.string(
                    "mobile.simulatorStream.waitingDetail",
                    defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "iphone"
            )
            .accessibilityIdentifier("SimulatorStreamV2Placeholder")
        case .reconnecting:
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.stalled", defaultValue: "Reconnecting to Simulator"),
                detail: L10n.string(
                    "mobile.simulatorStream.stalledDetail",
                    defaultValue: "The video feed stalled. Restoring the stream."),
                symbol: "arrow.triangle.2.circlepath"
            )
            .accessibilityIdentifier("SimulatorStreamV2ReconnectingOverlay")
        case .unavailable(let detail):
            statusOverlay(
                title: L10n.string(
                    "mobile.simulatorStream.unavailable", defaultValue: "Simulator Unavailable"),
                detail: Self.unavailableDetailText(detail),
                symbol: "iphone.slash"
            )
            .accessibilityIdentifier("SimulatorStreamV2UnavailableOverlay")
        case .streaming, .stopped:
            EmptyView()
        }
    }

    /// Host detail strings are protocol tokens, never user-facing prose:
    /// known tokens map to localized copy and anything else falls back to
    /// the generic message, so raw host text is never rendered.
    private static func unavailableDetailText(_ detail: String) -> String {
        switch detail {
        case "superseded":
            return L10n.string(
                "mobile.simulatorStream.supersededDetail",
                defaultValue: "Another device took over this Simulator stream.")
        case "panel_closed", "panel_not_found":
            return L10n.string(
                "mobile.simulatorStream.panelClosedDetail",
                defaultValue: "The Simulator pane was closed on the Mac.")
        case "simulator_disabled":
            return L10n.string(
                "mobile.simulatorStream.disabledDetail",
                defaultValue: "Simulator panes are disabled on the Mac.")
        default:
            return L10n.string(
                "mobile.simulatorStream.unavailableDetail",
                defaultValue: "The Mac closed this Simulator stream.")
        }
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
        .allowsHitTesting(false)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField(
                L10n.string("mobile.simulatorStream.textPlaceholder", defaultValue: "Text"),
                text: $pendingText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.send)
            .focused($textFocused)
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .onSubmit { submitText() }
            .accessibilityIdentifier("SimulatorStreamV2TextField")

            chromeButton(
                systemImage: "paperplane",
                label: L10n.string("mobile.simulatorStream.sendText", defaultValue: "Send Text"),
                identifier: "SimulatorStreamV2SendTextButton",
                disabled: pendingText.isEmpty
            ) { submitText() }

            hardwareButton(
                .home, systemImage: "house",
                label: L10n.string("mobile.simulatorStream.home", defaultValue: "Home"),
                identifier: "SimulatorStreamV2HomeButton")
            hardwareButton(
                .lock, systemImage: "lock",
                label: L10n.string("mobile.simulatorStream.lock", defaultValue: "Lock"),
                identifier: "SimulatorStreamV2LockButton")

            Menu {
                menuButton(
                    .appSwitcher, systemImage: "rectangle.stack",
                    label: L10n.string(
                        "mobile.simulatorStream.appSwitcher", defaultValue: "App Switcher"))
                menuButton(
                    .volumeUp, systemImage: "speaker.plus",
                    label: L10n.string(
                        "mobile.simulatorStream.volumeUp", defaultValue: "Volume Up"))
                menuButton(
                    .volumeDown, systemImage: "speaker.minus",
                    label: L10n.string(
                        "mobile.simulatorStream.volumeDown", defaultValue: "Volume Down"))
                menuButton(
                    .siri, systemImage: "waveform",
                    label: L10n.string("mobile.simulatorStream.siri", defaultValue: "Siri"))
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 24, height: 24)
            }
            .accessibilityLabel(
                L10n.string("mobile.simulatorStream.moreButtons", defaultValue: "More Buttons")
            )
            .accessibilityIdentifier("SimulatorStreamV2MoreButtons")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Neutral chrome: the hardware-button icons read as controls, not
        // links, so they must not pick up the app accent color.
        .tint(.primary)
        .mobileGlassPill()
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func chromeButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 24, height: 24)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func hardwareButton(
        _ button: SimStreamHardwareButton,
        systemImage: String,
        label: String,
        identifier: String
    ) -> some View {
        chromeButton(
            systemImage: systemImage, label: label, identifier: identifier, disabled: false
        ) {
            store?.sendButton(button)
        }
    }

    private func menuButton(
        _ button: SimStreamHardwareButton, systemImage: String, label: String
    ) -> some View {
        Button {
            store?.sendButton(button)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func submitText() {
        let text = pendingText
        pendingText = ""
        store?.sendText(text)
    }
}

private struct SimStreamDisplayRepresentable: UIViewRepresentable {
    let store: SimulatorStreamV2Store

    func makeUIView(context: Context) -> SimStreamDisplayView {
        let view = SimStreamDisplayView()
        view.isUserInteractionEnabled = true
        view.onTouchEvent = { [weak store] event in
            store?.send(event)
        }
        store.bindPresenter(SimStreamViewPresenter(view: view))
        return view
    }

    func updateUIView(_ uiView: SimStreamDisplayView, context: Context) {}
}
#endif
