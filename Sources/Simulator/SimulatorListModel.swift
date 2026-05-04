import AppKit
import CoreImage
import IOSurface
import Observation
import SwiftUI

@MainActor
@Observable
final class SimulatorListModel {
    var devices: [SimulatorDevice] = []
    var loadError: String?
    var selectedUDID: String?
    var lastInputError: String?
    var capabilityReport: SimulatorCapabilityReport = SimulatorCapabilities.report()

    /// Logical point size for the currently selected device, fetched from
    /// `SimDeviceType.mainScreenSize`. Used as the unit the HID dispatch
    /// path expects. Nil when the property isn't exposed; we then fall
    /// back to the IOSurface's pixel dimensions.
    var devicePointSize: CGSize?

    @ObservationIgnored
    private var screen: SimulatorScreen?
    @ObservationIgnored
    private var input: IndigoHIDInput?
    @ObservationIgnored
    private var streamingUDID: String?
    @ObservationIgnored
    private weak var frameStore: SimulatorPreviewFrameStore?
    @ObservationIgnored
    private var refreshTimer: Timer?
    @ObservationIgnored
    private var refreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var isVisibleInUI: Bool = true
    @ObservationIgnored
    private let inputQueue = DispatchQueue(label: "cmux.simulator.input", qos: .userInteractive)
    @ObservationIgnored
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
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try SimulatorService.shared.listDevices()
                .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
            }
            await MainActor.run { [weak self] in
                self?.applyRefreshResult(result, generation: generation)
            }
        }
    }

    func boot(_ device: SimulatorDevice) {
        Task.detached(priority: .userInitiated) {
            do {
                try SimulatorService.shared.boot(udid: device.udid)
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
            await MainActor.run { [weak self] in self?.refresh() }
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
            await MainActor.run { [weak self] in self?.refresh() }
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
    /// We dispatch off-main so HID message construction and delivery stay
    /// out of the main loop.
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

    private func applyRefreshResult(_ result: Result<[SimulatorDevice], Error>, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        switch result {
        case .success(let refreshedDevices):
            devices = refreshedDevices
            loadError = nil
            reconcileSelectedDeviceState()
        case .failure(let error):
            loadError = error.localizedDescription
            devices = []
            stopStreaming()
        }
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
        let input = IndigoHIDInput(udid: udid, queue: inputQueue)
        self.input = input
        self.devicePointSize = nil
        self.lastInputError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let pointSize = SimulatorService.shared.deviceScreenSizeInPoints(udid: udid)
            await MainActor.run { [weak self] in
                guard self?.streamingUDID == udid else { return }
                self?.devicePointSize = pointSize
            }
        }
        screen.start(
            onFrame: { [weak self] surface, size in
                guard let self else { return }
                guard let image = Self.makeImage(from: surface, ciContext: self.ciContext) else { return }
                Task { @MainActor [weak self] in
                    guard self?.streamingUDID == udid else { return }
                    self?.frameStore?.update(image: image, imageSize: size)
                }
            },
            completion: { [weak self, weak screen] result in
                Task { @MainActor [weak self, weak screen] in
                    guard let self, self.screen === screen, self.streamingUDID == udid else { return }
                    if case .failure(let error) = result {
                        self.screen = nil
                        self.streamingUDID = nil
                        self.input = nil
                        self.loadError = error.localizedDescription
                    }
                }
            }
        )
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
