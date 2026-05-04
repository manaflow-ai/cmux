import AppKit
import IOSurface
import QuartzCore
import SwiftUI

public struct CMUXSimulatorViewer: View {
    private let runtime: CMUXSimulatorRuntime
    private let initialUDID: String?
    private let onDeviceSelected: (CMUXSimulatorDevice) -> Void
    private let onDetach: (() -> Void)?

    @State private var devices: [CMUXSimulatorDevice] = []
    @State private var selectedUDID: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var metrics = CMUXSimulatorFrameMetrics(pixelSize: .zero, fps: 0)

    public init(
        runtime: CMUXSimulatorRuntime = .shared,
        initialUDID: String? = nil,
        onDeviceSelected: @escaping (CMUXSimulatorDevice) -> Void = { _ in },
        onDetach: (() -> Void)? = nil
    ) {
        self.runtime = runtime
        self.initialUDID = initialUDID
        self.onDeviceSelected = onDeviceSelected
        self.onDetach = onDetach
        _selectedUDID = State(initialValue: initialUDID)
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .black)
            if let selectedUDID {
                CMUXSimulatorCanvas(
                    runtime: runtime,
                    udid: selectedUDID,
                    deviceSize: selectedDevice?.screenSizePoints ?? .zero,
                    onError: { errorMessage = $0 },
                    onStatus: { statusMessage = $0 },
                    onMetrics: { metrics = $0 }
                )
                .overlay(alignment: .topLeading) {
                    simulatorHUD
                }
                .contextMenu {
                    contextMenuItems
                }
            } else {
                picker
            }

            if let message = errorMessage {
                banner(message: message, isError: true)
            } else if let statusMessage {
                banner(message: statusMessage, isError: false)
            }
        }
        .task {
            loadDevices()
        }
    }

    private var selectedDevice: CMUXSimulatorDevice? {
        guard let selectedUDID else { return nil }
        return devices.first { $0.udid == selectedUDID }
    }

    private var picker: some View {
        VStack(spacing: 12) {
            Text(String(localized: "simulator.picker.title", defaultValue: "Choose a Simulator"))
                .font(.headline)
            if devices.isEmpty {
                Text(String(localized: "simulator.picker.empty", defaultValue: "No simulators found."))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groupedDevices, id: \.runtime) { group in
                            Text(group.runtime.isEmpty ? String(localized: "simulator.runtime.unknown", defaultValue: "Unknown Runtime") : group.runtime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(group.devices) { device in
                                Button {
                                    select(device)
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(device.isBooted ? Color.green : Color.secondary.opacity(0.45))
                                            .frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.system(size: 13, weight: .medium))
                                            Text("\(device.state.displayName) · \(device.shortUDID)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 360, height: 340)
            }
            Button(String(localized: "simulator.action.refresh", defaultValue: "Refresh")) {
                loadDevices()
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupedDevices: [(runtime: String, devices: [CMUXSimulatorDevice])] {
        Dictionary(grouping: devices, by: \.runtime)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.runtime < $1.runtime }
    }

    private var simulatorHUD: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                Circle()
                    .fill((selectedDevice?.isBooted ?? false) ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDevice?.name ?? String(localized: "simulator.device.loading", defaultValue: "Simulator"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(selectedDevice?.runtime ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            VStack(spacing: 6) {
                ForEach(CMUXSimulatorHardwareAction.allCases, id: \.rawValue) { action in
                    Button {
                        perform(action)
                    } label: {
                        Image(systemName: iconName(for: action))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(localizedActionTitle(action))
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            if let onDetach {
                Button {
                    onDetach()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "simulator.action.detach", defaultValue: "Detach"))
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            metricsView
                .offset(y: 34)
        }
        .padding(10)
    }

    private var metricsView: some View {
        let pointSize = selectedDevice?.screenSizePoints ?? .zero
        let pixelSize = metrics.pixelSize.width > 0 ? metrics.pixelSize : (selectedDevice?.screenSizePixels ?? .zero)
        return Text(
            String(
                format: "%.0f×%.0f pt · %.0f×%.0f px · %.0f fps · Touch",
                pointSize.width,
                pointSize.height,
                pixelSize.width,
                pixelSize.height,
                metrics.fps
            )
        )
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(String(localized: "simulator.action.home", defaultValue: "Home")) { perform(.home) }
        Button(String(localized: "simulator.action.lock", defaultValue: "Lock")) { perform(.lock) }
        Button(String(localized: "simulator.action.screenshot", defaultValue: "Screenshot")) { perform(.screenshot) }
        Button(String(localized: "simulator.action.shake", defaultValue: "Shake")) { perform(.shake) }
        Divider()
        Button(String(localized: "simulator.action.openInSimulator", defaultValue: "Open in Simulator.app")) {
            guard let selectedUDID else { return }
            do {
                try runtime.openInSimulatorApp(udid: selectedUDID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        Button(String(localized: "simulator.action.revealContainer", defaultValue: "Reveal Container in Finder")) {
            guard let selectedUDID else { return }
            runtime.revealDeviceContainer(udid: selectedUDID)
        }
        Button(String(localized: "simulator.action.copyUDID", defaultValue: "Copy UDID")) {
            guard let selectedUDID else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedUDID, forType: .string)
        }
    }

    private func banner(message: String, isError: Bool) -> some View {
        VStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isError ? Color.red.opacity(0.9) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            Spacer()
        }
    }

    private func select(_ device: CMUXSimulatorDevice) {
        selectedUDID = device.udid
        onDeviceSelected(device)
        if !device.isBooted {
            Task.detached {
                do {
                    try runtime.boot(udid: device.udid)
                } catch {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
                await MainActor.run { loadDevices() }
            }
        }
    }

    private func loadDevices() {
        Task.detached {
            do {
                let loaded = try runtime.listDevices()
                await MainActor.run {
                    devices = loaded
                    if let initialUDID,
                       selectedUDID == nil,
                       let matched = loaded.first(where: { $0.udid == initialUDID }) {
                        select(matched)
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func perform(_ action: CMUXSimulatorHardwareAction) {
        guard let selectedUDID else { return }
        Task.detached {
            do {
                let succeeded = try runtime.performHardwareAction(action, udid: selectedUDID)
                await MainActor.run {
                    statusMessage = succeeded ? localizedActionTitle(action) : String(localized: "simulator.action.failed", defaultValue: "Action failed")
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func iconName(for action: CMUXSimulatorHardwareAction) -> String {
        switch action {
        case .home: return "circle"
        case .lock: return "lock"
        case .volumeUp: return "speaker.wave.2"
        case .volumeDown: return "speaker.wave.1"
        case .screenshot: return "camera"
        case .rotateLeft: return "rotate.left"
        case .rotateRight: return "rotate.right"
        case .shake: return "waveform.path"
        }
    }

    private func localizedActionTitle(_ action: CMUXSimulatorHardwareAction) -> String {
        switch action {
        case .home: return String(localized: "simulator.action.home", defaultValue: "Home")
        case .lock: return String(localized: "simulator.action.lock", defaultValue: "Lock")
        case .volumeUp: return String(localized: "simulator.action.volumeUp", defaultValue: "Volume Up")
        case .volumeDown: return String(localized: "simulator.action.volumeDown", defaultValue: "Volume Down")
        case .screenshot: return String(localized: "simulator.action.screenshot", defaultValue: "Screenshot")
        case .rotateLeft: return String(localized: "simulator.action.rotateLeft", defaultValue: "Rotate Left")
        case .rotateRight: return String(localized: "simulator.action.rotateRight", defaultValue: "Rotate Right")
        case .shake: return String(localized: "simulator.action.shake", defaultValue: "Shake")
        }
    }
}

public struct CMUXSimulatorDebugView: View {
    private let runtime: CMUXSimulatorRuntime
    @State private var devices: [CMUXSimulatorDevice] = []
    @State private var selectedUDID: String?
    @State private var errorMessage: String?

    public init(runtime: CMUXSimulatorRuntime = .shared) {
        self.runtime = runtime
    }

    public var body: some View {
        NavigationSplitView {
            List(devices, selection: $selectedUDID) { device in
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    Text("\(device.runtime) · \(device.state.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(device.udid)
                .contextMenu {
                    Button(String(localized: "simulator.action.boot", defaultValue: "Boot")) { boot(device) }
                    Button(String(localized: "simulator.action.shutdown", defaultValue: "Shutdown")) { shutdown(device) }
                    Button(String(localized: "simulator.action.copyUDID", defaultValue: "Copy UDID")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(device.udid, forType: .string)
                    }
                }
            }
            .frame(minWidth: 260)
            .toolbar {
                Button {
                    loadDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(String(localized: "simulator.action.refresh", defaultValue: "Refresh"))
            }
        } detail: {
            CMUXSimulatorViewer(runtime: runtime, initialUDID: selectedUDID)
                .id(selectedUDID ?? "none")
        }
        .task {
            loadDevices()
        }
        .overlay(alignment: .top) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    private func loadDevices() {
        Task.detached {
            do {
                let loaded = try runtime.listDevices()
                await MainActor.run {
                    devices = loaded
                    if selectedUDID == nil {
                        selectedUDID = loaded.first(where: \.isBooted)?.udid ?? loaded.first?.udid
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func boot(_ device: CMUXSimulatorDevice) {
        Task.detached {
            do {
                try runtime.boot(udid: device.udid)
                await MainActor.run { loadDevices() }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func shutdown(_ device: CMUXSimulatorDevice) {
        Task.detached {
            do {
                try runtime.shutdown(udid: device.udid)
                await MainActor.run { loadDevices() }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct CMUXSimulatorCanvas: NSViewRepresentable {
    let runtime: CMUXSimulatorRuntime
    let udid: String
    let deviceSize: CMUXSimulatorSize
    let onError: (String) -> Void
    let onStatus: (String) -> Void
    let onMetrics: (CMUXSimulatorFrameMetrics) -> Void

    func makeNSView(context: Context) -> CMUXSimulatorCanvasView {
        let view = CMUXSimulatorCanvasView()
        view.configure(
            runtime: runtime,
            udid: udid,
            deviceSize: deviceSize,
            onError: onError,
            onStatus: onStatus,
            onMetrics: onMetrics
        )
        return view
    }

    func updateNSView(_ nsView: CMUXSimulatorCanvasView, context: Context) {
        nsView.configure(
            runtime: runtime,
            udid: udid,
            deviceSize: deviceSize,
            onError: onError,
            onStatus: onStatus,
            onMetrics: onMetrics
        )
    }
}

private final class CMUXSimulatorCanvasView: NSView {
    private let surfaceLayer = CALayer()
    private let pointerLayer = CAShapeLayer()
    private let frameQueue = DispatchQueue(label: "com.cmux.simulator.layer", qos: .userInteractive)

    private var runtime: CMUXSimulatorRuntime?
    private var udid: String?
    private var deviceSize = CMUXSimulatorSize.zero
    private var stream: CMUXSimulatorScreenStream?
    private var onError: ((String) -> Void)?
    private var onStatus: ((String) -> Void)?
    private var onMetrics: ((CMUXSimulatorFrameMetrics) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var isTouchDown = false
    private var twoFingerMode = false
    private var lastFrameTimes: [CFTimeInterval] = []
    private var lastMetricsEmission: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        surfaceLayer.contentsGravity = .resizeAspect
        surfaceLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(surfaceLayer)

        pointerLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        pointerLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        pointerLayer.lineWidth = 1
        pointerLayer.isHidden = true
        layer?.addSublayer(pointerLayer)

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    func configure(
        runtime: CMUXSimulatorRuntime,
        udid: String,
        deviceSize: CMUXSimulatorSize,
        onError: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void,
        onMetrics: @escaping (CMUXSimulatorFrameMetrics) -> Void
    ) {
        let changedDevice = self.udid != udid
        self.runtime = runtime
        self.udid = udid
        self.deviceSize = deviceSize
        self.onError = onError
        self.onStatus = onStatus
        self.onMetrics = onMetrics
        if changedDevice {
            startStream()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = bounds
        updatePointerLayer(at: nil)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerLayer.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        pointerLayer.isHidden = true
        if isTouchDown {
            finishTouch(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let point = devicePoint(for: event) else { return }
        updatePointerLayer(at: event.locationInWindow)
        _ = try? input()?.sendHover(at: point, size: effectiveDeviceSize())
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = devicePoint(for: event) else { return }
        isTouchDown = true
        twoFingerMode = event.modifierFlags.contains(.option)
        updatePointerLayer(at: event.locationInWindow)
        do {
            if twoFingerMode {
                let pair = twoFingerPoints(midpoint: point, event: event)
                _ = try input()?.sendTouch(phase: .down, first: pair.first, second: pair.second, size: effectiveDeviceSize())
            } else {
                _ = try input()?.sendTouch(phase: .down, first: point, second: nil, size: effectiveDeviceSize())
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouchDown, let point = devicePoint(for: event) else { return }
        updatePointerLayer(at: event.locationInWindow)
        do {
            if twoFingerMode {
                let pair = twoFingerPoints(midpoint: point, event: event)
                _ = try input()?.sendTouch(phase: .move, first: pair.first, second: pair.second, size: effectiveDeviceSize())
            } else {
                _ = try input()?.sendTouch(phase: .move, first: point, second: nil, size: effectiveDeviceSize())
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    override func mouseUp(with event: NSEvent) {
        finishTouch(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        do {
            _ = try input()?.sendScroll(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY))
        } catch {
            onError?(error.localizedDescription)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        onStatus?(String(localized: "simulator.keyboard.unsupported", defaultValue: "Keyboard input is not wired yet."))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let runtime,
              let udid,
              let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        var succeeded = false
        for url in items {
            do {
                try runtime.installOrCopyFile(url, udid: udid)
                succeeded = true
            } catch {
                onError?(error.localizedDescription)
            }
        }
        return succeeded
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        addMenuItem(String(localized: "simulator.action.home", defaultValue: "Home"), action: #selector(menuHome), to: menu)
        addMenuItem(String(localized: "simulator.action.lock", defaultValue: "Lock"), action: #selector(menuLock), to: menu)
        addMenuItem(String(localized: "simulator.action.screenshot", defaultValue: "Screenshot"), action: #selector(menuScreenshot), to: menu)
        addMenuItem(String(localized: "simulator.action.shake", defaultValue: "Shake"), action: #selector(menuShake), to: menu)
        menu.addItem(.separator())
        addMenuItem(String(localized: "simulator.action.openInSimulator", defaultValue: "Open in Simulator.app"), action: #selector(menuOpenInSimulator), to: menu)
        addMenuItem(String(localized: "simulator.action.revealContainer", defaultValue: "Reveal Container in Finder"), action: #selector(menuRevealContainer), to: menu)
        addMenuItem(String(localized: "simulator.action.copyUDID", defaultValue: "Copy UDID"), action: #selector(menuCopyUDID), to: menu)
        return menu
    }

    private func startStream() {
        stream?.stop()
        stream = nil
        guard let runtime, let udid else { return }
        do {
            let stream = try runtime.screenStream(udid: udid)
            self.stream = stream
            try stream.start { [weak self] surface in
                self?.display(surface)
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func display(_ surface: IOSurface) {
        frameQueue.async { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.surfaceLayer.contents = surface
            CATransaction.commit()
            self.recordFrame(surface)
        }
    }

    private func recordFrame(_ surface: IOSurface) {
        let now = CACurrentMediaTime()
        lastFrameTimes.append(now)
        lastFrameTimes = lastFrameTimes.filter { now - $0 <= 1.0 }
        guard now - lastMetricsEmission > 0.5 else { return }
        lastMetricsEmission = now
        let metrics = CMUXSimulatorFrameMetrics(
            pixelSize: CMUXSimulatorSize(
                width: Double(IOSurfaceGetWidth(surface)),
                height: Double(IOSurfaceGetHeight(surface))
            ),
            fps: Double(lastFrameTimes.count)
        )
        DispatchQueue.main.async { [weak self] in
            self?.onMetrics?(metrics)
        }
    }

    private func finishTouch(with event: NSEvent) {
        guard isTouchDown, let point = devicePoint(for: event) else {
            isTouchDown = false
            twoFingerMode = false
            return
        }
        defer {
            isTouchDown = false
            twoFingerMode = false
        }
        do {
            if twoFingerMode {
                let pair = twoFingerPoints(midpoint: point, event: event)
                _ = try input()?.sendTouch(phase: .up, first: pair.first, second: pair.second, size: effectiveDeviceSize())
            } else {
                _ = try input()?.sendTouch(phase: .up, first: point, second: nil, size: effectiveDeviceSize())
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func input() throws -> CMUXSimulatorHIDInput? {
        guard let runtime, let udid else { return nil }
        return try runtime.inputSession(udid: udid)
    }

    private func effectiveDeviceSize() -> CMUXSimulatorSize {
        if deviceSize.width > 0, deviceSize.height > 0 {
            return deviceSize
        }
        return CMUXSimulatorSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
    }

    private func devicePoint(for event: NSEvent) -> CMUXSimulatorPoint? {
        let local = convert(event.locationInWindow, from: nil)
        let rect = contentRect()
        guard rect.contains(local), rect.width > 0, rect.height > 0 else { return nil }
        let size = effectiveDeviceSize()
        let x = Double((local.x - rect.minX) / rect.width) * size.width
        let y = Double((rect.maxY - local.y) / rect.height) * size.height
        return CMUXSimulatorPoint(x: x, y: y)
    }

    private func contentRect() -> CGRect {
        let size = effectiveDeviceSize()
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let targetAspect = CGFloat(size.width / size.height)
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > targetAspect {
            let width = bounds.height * targetAspect
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / targetAspect
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }

    private func twoFingerPoints(midpoint: CMUXSimulatorPoint, event: NSEvent) -> (first: CMUXSimulatorPoint, second: CMUXSimulatorPoint) {
        let spread = event.modifierFlags.contains(.shift) ? 160.0 : 96.0
        return (
            CMUXSimulatorPoint(x: midpoint.x - spread / 2, y: midpoint.y),
            CMUXSimulatorPoint(x: midpoint.x + spread / 2, y: midpoint.y)
        )
    }

    private func updatePointerLayer(at windowPoint: NSPoint?) {
        guard let windowPoint else {
            pointerLayer.isHidden = true
            return
        }
        let local = convert(windowPoint, from: nil)
        let radius: CGFloat = 5
        pointerLayer.path = CGPath(ellipseIn: CGRect(x: local.x - radius, y: local.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        pointerLayer.isHidden = false
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuHome() { perform(.home) }
    @objc private func menuLock() { perform(.lock) }
    @objc private func menuScreenshot() { perform(.screenshot) }
    @objc private func menuShake() { perform(.shake) }

    @objc private func menuOpenInSimulator() {
        guard let runtime, let udid else { return }
        do {
            try runtime.openInSimulatorApp(udid: udid)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    @objc private func menuRevealContainer() {
        guard let runtime, let udid else { return }
        runtime.revealDeviceContainer(udid: udid)
    }

    @objc private func menuCopyUDID() {
        guard let udid else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(udid, forType: .string)
    }

    private func perform(_ action: CMUXSimulatorHardwareAction) {
        guard let runtime, let udid else { return }
        do {
            _ = try runtime.performHardwareAction(action, udid: udid)
            onStatus?(localizedActionTitle(action))
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func localizedActionTitle(_ action: CMUXSimulatorHardwareAction) -> String {
        switch action {
        case .home: return String(localized: "simulator.action.home", defaultValue: "Home")
        case .lock: return String(localized: "simulator.action.lock", defaultValue: "Lock")
        case .volumeUp: return String(localized: "simulator.action.volumeUp", defaultValue: "Volume Up")
        case .volumeDown: return String(localized: "simulator.action.volumeDown", defaultValue: "Volume Down")
        case .screenshot: return String(localized: "simulator.action.screenshot", defaultValue: "Screenshot")
        case .rotateLeft: return String(localized: "simulator.action.rotateLeft", defaultValue: "Rotate Left")
        case .rotateRight: return String(localized: "simulator.action.rotateRight", defaultValue: "Rotate Right")
        case .shake: return String(localized: "simulator.action.shake", defaultValue: "Shake")
        }
    }
}
