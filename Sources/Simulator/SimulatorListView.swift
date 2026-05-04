import AppKit
import IOSurface
import SwiftUI
import CoreImage

@MainActor
final class SimulatorListModel: ObservableObject {
    @Published var devices: [SimulatorDevice] = []
    @Published var loadError: String?
    @Published var selectedUDID: String?
    @Published var lastFrame: NSImage?
    @Published var lastFrameSize: CGSize = .zero
    @Published var lastInputError: String?
    @Published var capabilityReport: SimulatorCapabilityReport = SimulatorCapabilities.report()

    /// Logical point size for the currently selected device, fetched from
    /// `SimDeviceType.mainScreenSize`. Used as the unit the HID dispatch
    /// path expects. Nil when the property isn't exposed; we then fall
    /// back to the IOSurface's pixel dimensions.
    @Published var devicePointSize: CGSize?

    private var screen: SimulatorScreen?
    private var input: IndigoHIDInput?
    private var refreshTimer: Timer?
    nonisolated private let ciContext = CIContext()

    /// Touch dispatch unit. Prefers points (matches what
    /// IndigoHIDMessageForMouseNSEvent's `widthPoints`/`heightPoints`
    /// args want); falls back to pixel size from the latest frame.
    var touchUnit: CGSize {
        if let p = devicePointSize, p.width > 0, p.height > 0 { return p }
        return lastFrameSize
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
            if let sel = selectedUDID, devices.first(where: { $0.udid == sel }) == nil {
                selectedUDID = nil
                stopStreaming()
            }
        } catch {
            loadError = error.localizedDescription
            devices = []
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
            selectedUDID = udid
        }
    }

    // MARK: - input

    func tap(at pointInDeviceUnits: CGPoint) {
        guard let input else { return }
        let size = touchUnit
        guard size.width > 0, size.height > 0 else { return }
        Task.detached { [weak self] in
            let ok = input.tap(at: pointInDeviceUnits, deviceSize: size)
            await self?.recordInputResult(ok: ok, fallback: input.lastError)
        }
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        guard let input else { return }
        let size = touchUnit
        guard size.width > 0, size.height > 0 else { return }
        Task.detached { [weak self] in
            let ok = input.drag(from: start, to: end, deviceSize: size)
            await self?.recordInputResult(ok: ok, fallback: input.lastError)
        }
    }

    func press(_ button: SimulatorButton) {
        guard let input else { return }
        Task.detached { [weak self] in
            let ok = input.press(button)
            await self?.recordInputResult(ok: ok, fallback: input.lastError)
        }
    }

    private func recordInputResult(ok: Bool, fallback: String?) {
        lastInputError = ok ? nil : (fallback ?? "input dispatch failed")
    }

    // MARK: - lifecycle

    private func startStreaming(udid: String) {
        let screen = SimulatorScreen(udid: udid)
        self.screen = screen
        self.input = IndigoHIDInput(udid: udid)
        self.devicePointSize = SimulatorService.shared.deviceScreenSizeInPoints(udid: udid)
        self.lastInputError = nil
        do {
            try screen.start { [weak self] surface, size in
                guard let self else { return }
                guard let image = Self.makeImage(from: surface, ciContext: self.ciContext) else { return }
                Task { @MainActor in
                    self.lastFrame = image
                    self.lastFrameSize = size
                }
            }
        } catch {
            self.screen = nil
            self.input = nil
            loadError = error.localizedDescription
        }
    }

    private func stopStreaming() {
        screen?.stop()
        screen = nil
        input = nil
        lastFrame = nil
        lastFrameSize = .zero
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
            model.startAutoRefresh()
            if let initialUDID { model.selectByUDID(initialUDID) }
        }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: - panes

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
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
                    Section(runtime.isEmpty ? "Other" : runtime) {
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
                        Text("Input: \(inputErr)")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if !report.input.isAvailable, let r = report.input.reasonText {
                        Text("Touch HID unavailable: \(r)")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if !report.screen.isAvailable, let r = report.screen.reasonText {
                        Text("Screen mirror unavailable: \(r)")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    if let xc = report.xcodeVersion {
                        Text("Xcode \(xc)")
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
                Text("Select a booted simulator")
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
                if let frame = model.lastFrame, model.lastFrameSize != .zero {
                    let rendered = renderRect(for: model.lastFrameSize, in: proxy.size)
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
                        Text("Boot the device to see its screen.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else if model.selectedUDID != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No device selected")
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
            .help("Home button")
            .disabled(!isBootedSelection)

            Button {
                model.press(.lock)
            } label: {
                Image(systemName: "lock").imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help("Lock button")
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
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let start = devicePoint(viewPoint: value.startLocation, rendered: rendered)
                let end = devicePoint(viewPoint: value.location, rendered: rendered)
                let dx = end.x - start.x
                let dy = end.y - start.y
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist < 6 {
                    model.tap(at: start)
                } else {
                    model.drag(from: start, to: end)
                }
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
            Button("Shutdown") { model.shutdown(device) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        case .shutdown, .unknown:
            Button("Boot") { model.boot(device) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        case .booting:
            Text("Booting…").font(.system(size: 11)).foregroundColor(.secondary)
        case .shuttingDown:
            Text("Shutting down…").font(.system(size: 11)).foregroundColor(.secondary)
        case .creating:
            Text("Creating…").font(.system(size: 11)).foregroundColor(.secondary)
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
        guard model.lastFrameSize != .zero else { return "" }
        let pixels = "\(Int(model.lastFrameSize.width))×\(Int(model.lastFrameSize.height))px"
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
