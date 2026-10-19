#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
@preconcurrency import UIKit

/// Serializes pointer delivery: gesture callbacks yield into one buffered
/// stream that a single lifecycle-owned task drains in order, because
/// independent per-event `Task`s have no ordering guarantee and could land a
/// `.moved` on the Mac before its `.began`. Yields while no consumer is
/// attached (pane unmounted) are dropped.
@MainActor
private final class SimulatorPointerPipe {
    private var continuation: AsyncStream<MobileSimulatorPointerInput>.Continuation?

    nonisolated init() {}

    func send(_ input: MobileSimulatorPointerInput) {
        continuation?.yield(input)
    }

    /// Vends a fresh stream per consuming `.task` run so a remount after
    /// cancellation gets a live pipe instead of a terminated stream.
    func makeStream() -> AsyncStream<MobileSimulatorPointerInput> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: MobileSimulatorPointerInput.self)
        self.continuation = continuation
        return stream
    }
}

struct SimulatorStreamPane: View {
    // Owned by `MobileSimulatorStreamStore`; held as a plain reference (not
    // `@State`) so a parent that reuses this view identity with a different
    // panel's state observes the new object instead of the first render's.
    private let state: MobileSimulatorStreamSurfaceState
    @State private var framePresenter: SimulatorFramePresentationPipeline<SimulatorPresentedImage>
    @State private var pendingText = ""
    @State private var pointerSequenceActive = false
    @State private var pointerMovedBeyondTapThreshold = false
    @State private var paneSize = CGSize.zero
    @State private var pointerPipe = SimulatorPointerPipe()
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
        self.state = state
        self.workspaceID = workspaceID
        self.actions = actions
        self.reconnect = reconnect
        _framePresenter = State(initialValue: SimulatorFramePresentationPipeline(
            decoder: SimulatorPresentedImage.decode
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.055, green: 0.063, blue: 0.075)
                if let presented = framePresenter.presented {
                    Image(uiImage: presented.value.image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(touchGesture(viewSize: paneSize))
                        .accessibilityIdentifier("SimulatorStreamImage")
                }
                paneOverlay
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                paneSize = size
            }
            bottomBar
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.075).ignoresSafeArea())
        .task(id: state.latestFrame.map { SimulatorStreamFrameIdentity(
            panelID: $0.panelID,
            sequence: $0.sequence,
            receiptRevision: state.latestFrameReceiptRevision
        ) }) {
            guard let frame = state.latestFrame else { return }
            framePresenter.submit(
                frame,
                allowDuplicateSequence: state.streamStatus == .stalled
            )
        }
        .onDisappear { framePresenter.cancel() }
        .task {
            for await event in framePresenter.events {
                guard !Task.isCancelled else { return }
                await handlePresentationEvent(event)
            }
        }
        .task {
            for await input in pointerPipe.makeStream() {
                await actions.pointer(input)
            }
        }
        .accessibilityIdentifier("SimulatorStreamPane")
    }

    private var imageSize: CGSize {
        guard let frame = framePresenter.presented?.frame else { return .zero }
        return CGSize(width: frame.pixelWidth, height: frame.pixelHeight)
    }

    private func touchGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.isOwnedByCurrentConnection else {
                    recordPointerBlocked(.moved)
                    return
                }
                let mapper = SimulatorStreamCoordinateMapper(viewSize: viewSize, imageSize: imageSize)
                guard touchPointPolicy.isDrag(start: value.startLocation, location: value.location) else {
                    return
                }
                if !pointerSequenceActive {
                    pointerSequenceActive = true
                    pointerMovedBeyondTapThreshold = true
                    sendPointer(.began, point: value.startLocation, mapper: mapper)
                }
                sendPointer(.moved, point: value.location, mapper: mapper)
            }
            .onEnded { value in
                guard state.isOwnedByCurrentConnection else {
                    recordPointerBlocked(.tap)
                    resetPointerSequence()
                    return
                }
                let mapper = SimulatorStreamCoordinateMapper(viewSize: viewSize, imageSize: imageSize)
                let isDrag = pointerMovedBeyondTapThreshold || touchPointPolicy.isDrag(
                    start: value.startLocation,
                    location: value.location
                )
                if isDrag {
                    if !pointerSequenceActive {
                        sendPointer(.began, point: value.startLocation, mapper: mapper)
                    }
                    sendPointer(.ended, point: value.location, mapper: mapper)
                } else {
                    sendPointer(.tap, point: value.startLocation, mapper: mapper)
                }
                resetPointerSequence()
            }
    }

    private func resetPointerSequence() {
        pointerSequenceActive = false
        pointerMovedBeyondTapThreshold = false
    }

    private func sendPointer(
        _ phase: MobileSimulatorPointerPhase,
        point: CGPoint,
        mapper: SimulatorStreamCoordinateMapper
    ) {
        let imageRect = mapper.fittedImageRect
        guard !imageRect.isEmpty else {
            recordCoordinate(point, mapper: mapper, mapping: .zeroImage)
            return
        }
        if !imageRect.contains(point) {
            recordCoordinate(point, mapper: mapper, mapping: .outsideImage)
        }
        guard let normalized = mapper.normalizedPoint(from: point) else {
            recordCoordinate(point, mapper: mapper, mapping: .zeroImage)
            return
        }
        let input = MobileSimulatorPointerInput(
            panelID: state.id,
            workspaceID: workspaceID,
            phase: phase,
            x: Double(normalized.x),
            y: Double(normalized.y)
        )
        pointerPipe.send(input)
    }

    private func recordPointerBlocked(_ phase: MobileSimulatorPointerPhase) {
        let detail = Self.diagnosticPointerPhase(phase).rawValue
        Task {
            await actions.inputDiagnostic(state.id, .blockedViewOnly, .pointer, detail)
        }
    }

    private func recordCoordinate(
        _ point: CGPoint,
        mapper: SimulatorStreamCoordinateMapper,
        mapping: DiagnosticSimulatorCoordinateState
    ) {
        let normalized = diagnosticViewPoint(point, viewSize: mapper.viewSize)
        let x = Double(normalized.x)
        let y = Double(normalized.y)
        Task {
            await actions.coordinate(state.id, x, y, mapping)
        }
    }

    private func diagnosticViewPoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / viewSize.width, 0), 1),
            y: min(max(point.y / viewSize.height, 0), 1)
        )
    }

    private static func diagnosticPointerPhase(
        _ phase: MobileSimulatorPointerPhase
    ) -> DiagnosticSimulatorPointerPhase {
        switch phase {
        case .began:
            return .began
        case .moved:
            return .moved
        case .ended:
            return .ended
        case .tap:
            return .tap
        }
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
        } else if state.streamStatus == .stalled {
            statusOverlay(
                title: L10n.string("mobile.simulatorStream.stalled", defaultValue: "Reconnecting to Simulator"),
                detail: L10n.string("mobile.simulatorStream.stalledDetail", defaultValue: "The video feed stalled. Restoring the stream."),
                symbol: "arrow.triangle.2.circlepath"
            )
            .accessibilityIdentifier("SimulatorStreamStalledOverlay")
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
            .allowsHitTesting(false)
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

    private func handlePresentationEvent(
        _ event: SimulatorFramePresentationPipeline<SimulatorPresentedImage>.Event
    ) async {
        let frame: MobileSimulatorFrameEvent
        let diagnostic: DiagnosticSimulatorFrameLifecycle
        switch event {
        case .presented(let presentedFrame):
            frame = presentedFrame
            diagnostic = .imageDecoded
            await actions.presentationSucceeded(frame.panelID)
        case .decodeFailed(let failedFrame):
            frame = failedFrame
            diagnostic = .imageDecodeFailed
        case .discarded(let discardedFrame):
            frame = discardedFrame
            diagnostic = .staleIgnored
        case .presentationStalled(let stalledFrame):
            await actions.presentationStalled(stalledFrame.panelID)
            return
        }
        await actions.frameDiagnostic(
            frame.panelID,
            diagnostic,
            frame.sequence,
            frame.dataBase64.utf8.count
        )
    }
}

private struct SimulatorStreamFrameIdentity: Hashable {
    let panelID: String
    let sequence: UInt64
    let receiptRevision: UInt64
}
#endif
