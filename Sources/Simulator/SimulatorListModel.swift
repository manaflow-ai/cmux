import AppKit
import CoreImage
import IOSurface
import SwiftUI

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
    private var isVisibleInUI: Bool = true
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

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        if visible {
            reconcileSelectedDeviceState()
        } else {
            stopStreaming()
        }
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
        guard isVisibleInUI, let device, device.isBooted else { return }
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
    /// translates a SwiftUI DragGesture into down -> move -> ... -> move -> up.
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

    private func reconcileSelectedDeviceState() {
        guard let selectedUDID else {
            stopStreaming()
            return
        }
        guard isVisibleInUI else {
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
        inputQueue.async { _ = input.prewarm() }
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
