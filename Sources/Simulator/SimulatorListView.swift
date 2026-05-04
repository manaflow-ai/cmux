import AppKit
import IOSurface
import SwiftUI
import CoreImage

@MainActor
final class SimulatorPreviewFrameStore: ObservableObject {
    @Published var image: NSImage?
    @Published var imageSize: CGSize = .zero

    func update(image: NSImage, imageSize: CGSize) {
        self.image = image
        self.imageSize = imageSize
    }

    func clear() {
        image = nil
        imageSize = .zero
    }
}

@MainActor
final class SimulatorListModel: ObservableObject {
    @Published var devices: [SimulatorDevice] = []
    @Published var loadError: String?
    @Published var selectedUDID: String?
    @Published var lastInputError: String?
    @Published var capabilityReport: SimulatorCapabilityReport = SimulatorCapabilities.report()

    /// Logical point size for the currently selected device, fetched from
    /// `SimDeviceType.mainScreenSize`. Used as the unit the HID dispatch
    /// path expects. Nil when the property isn't exposed; we then fall
    /// back to the IOSurface's pixel dimensions.
    @Published var devicePointSize: CGSize?

    private var screen: SimulatorScreen?
    private var input: IndigoHIDInput?
    private var streamingUDID: String?
    private weak var frameStore: SimulatorPreviewFrameStore?
    private var refreshTimer: Timer?
    private let inputQueue = DispatchQueue(label: "cmux.simulator.input", qos: .userInteractive)
    nonisolated private let ciContext = CIContext()

    /// Touch dispatch unit. Prefers points (matches what
    /// IndigoHIDMessageForMouseNSEvent's `widthPoints`/`heightPoints`
    /// args want); falls back to pixel size from the latest frame.
    var touchUnit: CGSize {
        if let p = devicePointSize, p.width > 0, p.height > 0 { return p }
        return frameStore?.imageSize ?? .zero
    }

    func attachFrameStore(_ frameStore: SimulatorPreviewFrameStore) {
        self.frameStore = frameStore
    }

    func startAutoRefresh() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopStreaming()
    }

    func refresh() {
        do {
            devices = try SimulatorService.shared.listDevices()
                .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
            loadError = nil
            reconcileSelectedDeviceState()
        } catch {
            loadError = error.localizedDescription
            devices = []
            stopStreaming()
        }
    }

    func boot(_ device: SimulatorDevice) {
        Task.detached(priority: .userInitiated) {
            do {
                try SimulatorService.shared.boot(udid: device.udid)
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
            await MainActor.run { self.refresh() }
        }
    }

    func shutdown(_ device: SimulatorDevice) {
        if device.udid == selectedUDID {
            stopStreaming()
        }
        Task.detached(priority: .userInitiated) {
            do {
                try SimulatorService.shared.shutdown(udid: device.udid)
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
            await MainActor.run { self.refresh() }
        }
    }

    func select(_ device: SimulatorDevice?) {
        stopStreaming()
        selectedUDID = device?.udid
        guard let device, device.isBooted else { return }
        startStreaming(udid: device.udid)
    }

    func selectByUDID(_ udid: String?) {
        guard let udid else { select(nil); return }
        if let device = devices.first(where: { $0.udid == udid }) {
            select(device)
        } else {
            stopStreaming()
            selectedUDID = udid
        }
    }

    // MARK: - input

    func tap(at pointInDeviceUnits: CGPoint) {
        guard let input else { return }
        let size = touchUnit
        guard size.width > 0, size.height > 0 else { return }
        dispatchInput {
            let ok = input.tap(at: pointInDeviceUnits, deviceSize: size)
            return (ok, input.lastError)
        }
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        guard let input else { return }
        let size = touchUnit
        guard size.width > 0, size.height > 0 else { return }
        dispatchInput {
            let ok = input.drag(from: start, to: end, deviceSize: size)
            return (ok, input.lastError)
        }
    }

    /// Streams a single touch phase to the simulator. The view's gesture
    /// translates a SwiftUI DragGesture into down → move → … → move → up.
    /// We dispatch off-main so any per-event retry sleeps inside
    /// IndigoHIDInput don't stutter the main loop.
    func sendTouchPhase(_ phase: IndigoHIDInput.TouchPhase, at pointInDeviceUnits: CGPoint) {
        guard let input else { return }
        let size = touchUnit
        guard size.width > 0, size.height > 0 else { return }
        dispatchInput {
            let ok = input.touchPhase(phase, at: pointInDeviceUnits, deviceSize: size)
            return (ok, input.lastError)
        }
    }

    func press(_ button: SimulatorButton) {
        guard let input else { return }
        dispatchInput {
            let ok = input.press(button)
            return (ok, input.lastError)
        }
    }

    private func dispatchInput(_ operation: @escaping @Sendable () -> (Bool, String?)) {
        inputQueue.async { [weak self] in
            let result = operation()
            Task { @MainActor [weak self] in
                self?.recordInputResult(ok: result.0, fallback: result.1)
            }
        }
    }

    private func recordInputResult(ok: Bool, fallback: String?) {
        lastInputError = ok
            ? nil
            : (
                fallback ?? String(
                    localized: "simulator.input.dispatchFailed",
                    defaultValue: "input dispatch failed"
                )
            )
    }

    // MARK: - lifecycle

    private func reconcileSelectedDeviceState() {
        guard let selectedUDID else {
            stopStreaming()
            return
        }
        guard let device = devices.first(where: { $0.udid == selectedUDID }) else {
            self.selectedUDID = nil
            stopStreaming()
            return
        }
        if device.isBooted {
            if streamingUDID != selectedUDID || screen == nil {
                stopStreaming()
                startStreaming(udid: selectedUDID)
            }
        } else if streamingUDID == selectedUDID || screen != nil {
            stopStreaming()
        } else {
            frameStore?.clear()
        }
    }

    private func startStreaming(udid: String) {
        let screen = SimulatorScreen(udid: udid)
        self.screen = screen
        self.streamingUDID = udid
        let input = IndigoHIDInput(udid: udid)
        self.input = input
        self.devicePointSize = SimulatorService.shared.deviceScreenSizeInPoints(udid: udid)
        self.lastInputError = nil
        do {
            try screen.start { [weak self] surface, size in
                guard let self else { return }
                guard let image = Self.makeImage(from: surface, ciContext: self.ciContext) else { return }
                Task { @MainActor [weak self] in
                    guard self?.streamingUDID == udid else { return }
                    self?.frameStore?.update(image: image, imageSize: size)
                }
            }
        } catch {
            self.screen = nil
            self.streamingUDID = nil
            self.input = nil
            loadError = error.localizedDescription
            return
        }
        // Pre-warm the HID client so the first mousedown doesn't pay
        // the ~40ms pointer/mouse service warmup cost.
        Task.detached { _ = input.prewarm() }
    }

    private func stopStreaming() {
        screen?.stop()
        screen = nil
        streamingUDID = nil
        input = nil
        frameStore?.clear()
        devicePointSize = nil
        lastInputError = nil
    }

    nonisolated private static func makeImage(from surface: IOSurface, ciContext: CIContext) -> NSImage? {
        let ci = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let size = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: size)
    }
}

/// SwiftUI view used by both the Debug Window and the bonsplit panel.
/// `initialUDID` selects a device automatically when the view appears.
struct SimulatorListView: View {
    @StateObject private var model = SimulatorListModel()
    @StateObject private var frameStore = SimulatorPreviewFrameStore()
    @State private var isTouchActive: Bool = false
    var initialUDID: String?
    var hidesDeviceList: Bool = false

    var body: some View {
        Group {
            if hidesDeviceList {
                preview
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 280)
                    preview
                        .frame(minWidth: 320)
                }
            }
        }
        .onAppear {
            model.attachFrameStore(frameStore)
            model.startAutoRefresh()
            if let initialUDID { model.selectByUDID(initialUDID) }
        }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: - panes

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "simulator.devices.title", defaultValue: "Devices"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "simulator.refresh.help", defaultValue: "Refresh"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let err = model.loadError {
                ScrollView {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            List(selection: Binding(
                get: { model.selectedUDID },
                set: { model.selectByUDID($0) }
            )) {
                ForEach(groupedRuntimes, id: \.self) { runtime in
                    Section(runtime.isEmpty ? String(localized: "simulator.runtime.other", defaultValue: "Other") : runtime) {
                        ForEach(devicesByRuntime[runtime, default: []]) { device in
                            row(for: device)
                                .tag(Optional(device.udid))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
            capabilityBanner
            previewCanvas
            Divider()
            previewToolbar
        }
    }

    @ViewBuilder
    private var capabilityBanner: some View {
        let report = model.capabilityReport
        let inputErr = model.lastInputError
        if !report.input.isAvailable || !report.screen.isAvailable || inputErr != nil {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 2) {
                    if let inputErr {
                        Text(
                            String(
                                localized: "simulator.input.errorFormat",
                                defaultValue: "Input: \(inputErr)"
                            )
                        )
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if !report.input.isAvailable, let r = report.input.reasonText {
                        Text(
                            String(
                                localized: "simulator.touchHIDUnavailableFormat",
                                defaultValue: "Touch HID unavailable: \(r)"
                            )
                        )
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if !report.screen.isAvailable, let r = report.screen.reasonText {
                        Text(
                            String(
                                localized: "simulator.screenMirrorUnavailableFormat",
                                defaultValue: "Screen mirror unavailable: \(r)"
                            )
                        )
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if let xc = report.xcodeVersion {
                        Text(
                            String(
                                localized: "simulator.xcodeVersionFormat",
                                defaultValue: "Xcode \(xc)"
                            )
                        )
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    private var previewHeader: some View {
        HStack {
            if let udid = model.selectedUDID,
               let device = model.devices.first(where: { $0.udid == udid }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 12, weight: .semibold))
                    Text(device.runtime).font(.system(size: 10)).foregroundColor(.secondary)
                }
            } else {
                Text(String(localized: "simulator.preview.selectBooted", defaultValue: "Select a booted simulator"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var previewCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.04)
                if let frame = frameStore.image, frameStore.imageSize != .zero {
                    let rendered = renderRect(for: frameStore.imageSize, in: proxy.size)
                    Image(nsImage: frame)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rendered.width, height: rendered.height)
                        .position(x: rendered.midX, y: rendered.midY)
                        .gesture(dragGesture(in: rendered))
                } else if let udid = model.selectedUDID,
                          let device = model.devices.first(where: { $0.udid == udid }),
                          !device.isBooted {
                    VStack(spacing: 6) {
                        Image(systemName: "iphone.slash").font(.system(size: 28))
                        Text(String(localized: "simulator.preview.bootPrompt", defaultValue: "Boot the device to see its screen."))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else if model.selectedUDID != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(String(localized: "simulator.preview.noDevice", defaultValue: "No device selected"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.press(.home)
            } label: {
                Image(systemName: "house").imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help(String(localized: "simulator.button.home.help", defaultValue: "Home button"))
            .disabled(!isBootedSelection)

            Button {
                model.press(.lock)
            } label: {
                Image(systemName: "lock").imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help(String(localized: "simulator.button.lock.help", defaultValue: "Lock button"))
            .disabled(!isBootedSelection)

            Spacer()

            Text(deviceSizeCaption)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - gesture

    private func dragGesture(in rendered: CGRect) -> some Gesture {
        // Stream the gesture: first .onChanged becomes touch-down,
        // subsequent .onChanged become moves, .onEnded becomes touch-up.
        // This matches a real finger interaction so taps highlight icons
        // immediately and drags scrub in real time.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let p = devicePoint(viewPoint: value.location, rendered: rendered)
                if isTouchActive {
                    model.sendTouchPhase(.move, at: p)
                } else {
                    isTouchActive = true
                    model.sendTouchPhase(.down, at: p)
                }
            }
            .onEnded { value in
                let p = devicePoint(viewPoint: value.location, rendered: rendered)
                if !isTouchActive {
                    // Edge case: zero-distance click that bypassed onChanged.
                    model.sendTouchPhase(.down, at: p)
                }
                model.sendTouchPhase(.up, at: p)
                isTouchActive = false
            }
    }

    private func devicePoint(viewPoint: CGPoint, rendered: CGRect) -> CGPoint {
        let xRatio = (viewPoint.x - rendered.minX) / rendered.width
        let yRatio = (viewPoint.y - rendered.minY) / rendered.height
        let unit = model.touchUnit  // device points if known, otherwise pixel size
        let x = max(0, min(1, xRatio)) * unit.width
        let y = max(0, min(1, yRatio)) * unit.height
        return CGPoint(x: x, y: y)
    }

    private func renderRect(for content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        let x = (container.width - w) / 2
        let y = (container.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - rows

    private func row(for device: SimulatorDevice) -> some View {
        HStack(spacing: 8) {
            stateDot(for: device.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 12))
                Text(device.udid.prefix(8))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            actionButton(for: device)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionButton(for device: SimulatorDevice) -> some View {
        switch device.state {
        case .booted:
            Button(String(localized: "simulator.action.shutdown", defaultValue: "Shutdown")) { model.shutdown(device) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        case .shutdown, .unknown:
            Button(String(localized: "simulator.action.boot", defaultValue: "Boot")) { model.boot(device) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        case .booting:
            Text(String(localized: "simulator.state.booting", defaultValue: "Booting…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .shuttingDown:
            Text(String(localized: "simulator.state.shuttingDown", defaultValue: "Shutting down…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .creating:
            Text(String(localized: "simulator.state.creating", defaultValue: "Creating…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func stateDot(for state: SimulatorDevice.State) -> some View {
        let color: Color = {
            switch state {
            case .booted: return .green
            case .booting, .shuttingDown, .creating: return .orange
            case .shutdown, .unknown: return Color.secondary.opacity(0.5)
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var isBootedSelection: Bool {
        guard let udid = model.selectedUDID else { return false }
        return model.devices.first(where: { $0.udid == udid })?.isBooted == true
    }

    private var deviceSizeCaption: String {
        guard frameStore.imageSize != .zero else { return "" }
        let pixels = "\(Int(frameStore.imageSize.width))×\(Int(frameStore.imageSize.height))px"
        if let pt = model.devicePointSize {
            return "\(Int(pt.width))×\(Int(pt.height))pt · \(pixels)"
        }
        return pixels
    }

    private var groupedRuntimes: [String] {
        Array(Set(model.devices.map(\.runtime))).sorted()
    }

    private var devicesByRuntime: [String: [SimulatorDevice]] {
        Dictionary(grouping: model.devices, by: \.runtime)
    }
}
