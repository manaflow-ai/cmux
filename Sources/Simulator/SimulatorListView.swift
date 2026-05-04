import AppKit
import SwiftUI

/// SwiftUI view used by both the Debug Window and the bonsplit panel.
/// `initialUDID` selects a device automatically when the view appears.
struct SimulatorListView: View {
    @State private var model = SimulatorListModel()
    @State private var frameStore = SimulatorPreviewFrameStore()
    @State private var isTouchActive: Bool = false
    var initialUDID: String?
    var hidesDeviceList: Bool = false
    var isVisibleInUI: Bool = true

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
            model.setVisibleInUI(isVisibleInUI)
            if let initialUDID { model.selectByUDID(initialUDID) }
        }
        .onDisappear { model.stopAutoRefresh() }
        .onChange(of: isVisibleInUI) { _, visibleInUI in
            model.setVisibleInUI(visibleInUI)
        }
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
        guard rendered.width > 0, rendered.height > 0 else { return .zero }
        let xRatio = viewPoint.x / rendered.width
        let yRatio = viewPoint.y / rendered.height
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
