#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
@preconcurrency import UIKit

struct SimulatorStreamPane: View {
    @State private var state: MobileSimulatorStreamSurfaceState
    @State private var image: UIImage?
    @State private var imageSequence: UInt64?
    @State private var pendingText = ""
    @State private var dragStarted = false
    @FocusState private var textFocused: Bool

    private let workspaceID: String
    private let actions: SimulatorStreamSurfaceActions
    private let reconnect: () -> Void
    private let touchPointPolicy = SimulatorStreamTouchPointPolicy()

    init(
        state: MobileSimulatorStreamSurfaceState,
        workspaceID: String,
        actions: SimulatorStreamSurfaceActions,
        reconnect: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.workspaceID = workspaceID
        self.actions = actions
        self.reconnect = reconnect
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.055, green: 0.063, blue: 0.075)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .gesture(touchGesture(viewSize: proxy.size))
                            .accessibilityIdentifier("SimulatorStreamImage")
                    }
                    paneOverlay
                }
            }
            bottomBar
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.075).ignoresSafeArea())
        .task(id: state.latestFrame?.sequence) {
            decodeLatestFrame()
        }
        .accessibilityIdentifier("SimulatorStreamPane")
    }

    private var imageSize: CGSize {
        guard let frame = state.latestFrame else { return .zero }
        return CGSize(width: frame.pixelWidth, height: frame.pixelHeight)
    }

    private func touchGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.isOwnedByCurrentConnection else { return }
                let mapper = SimulatorStreamCoordinateMapper(viewSize: viewSize, imageSize: imageSize)
                if !dragStarted {
                    dragStarted = true
                    sendPointer(.began, point: value.startLocation, mapper: mapper)
                }
                sendPointer(.moved, point: value.location, mapper: mapper)
            }
            .onEnded { value in
                guard state.isOwnedByCurrentConnection else {
                    dragStarted = false
                    return
                }
                let mapper = SimulatorStreamCoordinateMapper(viewSize: viewSize, imageSize: imageSize)
                let endPoint = touchPointPolicy.endPoint(
                    start: value.startLocation,
                    location: value.location
                )
                sendPointer(.ended, point: endPoint, mapper: mapper)
                dragStarted = false
            }
    }

    private func sendPointer(
        _ phase: MobileSimulatorPointerPhase,
        point: CGPoint,
        mapper: SimulatorStreamCoordinateMapper
    ) {
        guard let normalized = mapper.normalizedPoint(from: point) else { return }
        let input = MobileSimulatorPointerInput(
            panelID: state.id,
            workspaceID: workspaceID,
            phase: phase,
            x: Double(normalized.x),
            y: Double(normalized.y)
        )
        Task { await actions.pointer(input) }
    }

    @ViewBuilder
    private var paneOverlay: some View {
        if state.connectionStatus != .connected {
            disconnectedOverlay
        } else if state.streamStatus == .locked {
            statusOverlay(
                title: L10n.string("mobile.simulatorStream.locked", defaultValue: "Simulator In Use"),
                detail: L10n.string("mobile.simulatorStream.lockedDetail", defaultValue: "Another phone is controlling this Simulator."),
                symbol: "lock.circle"
            )
            .accessibilityIdentifier("SimulatorStreamLockedOverlay")
        } else if state.latestFrame == nil {
            statusOverlay(
                title: L10n.string("mobile.simulatorStream.waiting", defaultValue: "Waiting for Simulator"),
                detail: L10n.string("mobile.simulatorStream.waitingDetail", defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "iphone"
            )
            .accessibilityIdentifier("SimulatorStreamPlaceholder")
        } else {
            VStack {
                HStack {
                    ownershipPill
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var ownershipPill: some View {
        Label(
            ownershipPillText,
            systemImage: ownershipPillSymbol
        )
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.primary)
        .accessibilityIdentifier("SimulatorStreamOwnershipPill")
    }

    private var ownershipPillText: String {
        if state.isOwnedByCurrentConnection {
            return L10n.string("mobile.simulatorStream.owned", defaultValue: "iPhone Control")
        }
        if state.isControlHandshakePending {
            return L10n.string("mobile.simulatorStream.connectingControl", defaultValue: "Connecting")
        }
        return L10n.string("mobile.simulatorStream.viewOnly", defaultValue: "View Only")
    }

    private var ownershipPillSymbol: String {
        if state.isOwnedByCurrentConnection { return "hand.tap" }
        if state.isControlHandshakePending { return "antenna.radiowaves.left.and.right" }
        return "eye"
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
                        : L10n.string("mobile.simulatorStream.disconnected", defaultValue: "Simulator Disconnected")
                )
                .font(.headline)
                Text(
                    state.connectionStatus == .reconnecting
                        ? L10n.string("mobile.connection.reconnectingDescription", defaultValue: "Trying to reach the selected cmux build.")
                        : L10n.string("mobile.simulatorStream.disconnectedDetail", defaultValue: "Reconnect to the Mac to continue streaming.")
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
                    .accessibilityIdentifier("SimulatorStreamReconnectButton")
                }
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .accessibilityIdentifier("SimulatorStreamDisconnectedOverlay")
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
            .disabled(!state.isOwnedByCurrentConnection || !state.supportsKeyboard)
            .accessibilityIdentifier("SimulatorStreamTextField")

            chromeButton(
                systemImage: "paperplane",
                label: L10n.string("mobile.simulatorStream.sendText", defaultValue: "Send Text"),
                identifier: "SimulatorStreamSendTextButton",
                disabled: pendingText.isEmpty || !state.isOwnedByCurrentConnection || !state.supportsKeyboard
            ) { submitText() }

            hardwareButton(.home, systemImage: "house", labelKey: "mobile.simulatorStream.home", defaultValue: "Home")
            hardwareButton(.lock, systemImage: "lock", labelKey: "mobile.simulatorStream.lock", defaultValue: "Lock")

            Menu {
                Button {
                    sendButton(.appSwitcher)
                } label: {
                    Label(
                        L10n.string("mobile.simulatorStream.appSwitcher", defaultValue: "App Switcher"),
                        systemImage: "rectangle.stack"
                    )
                }
                Button {
                    sendButton(.volumeUp)
                } label: {
                    Label(
                        L10n.string("mobile.simulatorStream.volumeUp", defaultValue: "Volume Up"),
                        systemImage: "speaker.plus"
                    )
                }
                Button {
                    sendButton(.volumeDown)
                } label: {
                    Label(
                        L10n.string("mobile.simulatorStream.volumeDown", defaultValue: "Volume Down"),
                        systemImage: "speaker.minus"
                    )
                }
                Button {
                    sendButton(.siri)
                } label: {
                    Label(
                        L10n.string("mobile.simulatorStream.siri", defaultValue: "Siri"),
                        systemImage: "waveform"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 24, height: 24)
            }
            .disabled(!state.isOwnedByCurrentConnection || !state.supportsHardwareButtons)
            .accessibilityLabel(L10n.string("mobile.simulatorStream.moreButtons", defaultValue: "More Buttons"))
            .accessibilityIdentifier("SimulatorStreamMoreButtons")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .mobileGlassPill()
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func hardwareButton(
        _ button: MobileSimulatorHardwareButton,
        systemImage: String,
        labelKey: StaticString,
        defaultValue: String.LocalizationValue
    ) -> some View {
        chromeButton(
            systemImage: systemImage,
            label: L10n.string(labelKey, defaultValue: defaultValue),
            identifier: "SimulatorStreamButton-\(button.rawValue)",
            disabled: !state.isOwnedByCurrentConnection || !state.supportsHardwareButtons
        ) { sendButton(button) }
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

    private func submitText() {
        let text = pendingText
        guard !text.isEmpty else { return }
        pendingText = ""
        textFocused = false
        let input = MobileSimulatorTextInput(panelID: state.id, workspaceID: workspaceID, text: text)
        Task { await actions.text(input) }
    }

    private func sendButton(_ button: MobileSimulatorHardwareButton) {
        let input = MobileSimulatorButtonInput(panelID: state.id, workspaceID: workspaceID, button: button)
        Task { await actions.button(input) }
    }

    private func decodeLatestFrame() {
        guard let frame = state.latestFrame, imageSequence != frame.sequence else { return }
        guard let data = Data(base64Encoded: frame.dataBase64),
              let decoded = UIImage(data: data) else { return }
        image = decoded
        imageSequence = frame.sequence
    }
}
#endif
