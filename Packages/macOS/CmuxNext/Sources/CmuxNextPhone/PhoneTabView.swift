public import AppKit
import CmuxNextCompat

/// The phone tab: a device picker and action bar over the phone's screen.
/// The screen is a still frame refreshed after every change the service
/// reports (an input, a boot, a recording); there is no timer.
@MainActor
public final class PhoneTabView: NSView {
    let service: PhoneService
    private(set) var deviceID: PhoneDeviceID?
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let bootButton = NSButton()
    let shotButton = NSButton()
    let recordButton = NSButton()
    let sendButton = NSButton()
    let notesField = NSTextField()
    let screen = NSImageView()
    let status = NSTextField(labelWithString: "")
    private var observation: Task<Void, Never>?
    private var frameLoad: Task<Void, Never>?

    /// - Parameter device: the phone to show first; nil picks the service's default.
    public init(service: PhoneService, device: PhoneDeviceID?) {
        self.service = service
        deviceID = device
        super.init(frame: .zero)
        build()
        observation = Task { [weak self] in
            guard let service = self?.service else { return }
            for await _ in ObservationStream({ (service.changeCount, service.devices.count) }) {
                guard let self else { return }
                self.syncControls()
                self.reloadFrame()
            }
        }
        Task { [weak self] in await self?.start() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stops observing; the App calls this when the tab closes.
    public func close() {
        observation?.cancel()
        frameLoad?.cancel()
    }

    /// The phone this tab shows, as the tab's restore route (`sim:<udid>`).
    public var route: String? { deviceID?.description }

    private func start() async {
        do {
            try await service.reload()
            if deviceID == nil { deviceID = try await service.defaultDevice().id }
        } catch {
            show(error)
        }
        syncControls()
        reloadFrame()
    }

    var selected: PhoneDevice? { service.devices.first { $0.id == deviceID } }

    func syncControls() {
        picker.removeAllItems()
        if service.devices.isEmpty {
            picker.addItem(withTitle: PhoneStrings.noPhones)
            picker.isEnabled = false
        } else {
            picker.isEnabled = true
            for device in service.devices {
                let title = "\(device.name) · \(device.osVersion)" + (device.mode == .device ? " · \(PhoneStrings.realDevice)" : "")
                picker.addItem(withTitle: title)
                picker.lastItem?.representedObject = device.id.description
            }
            if let deviceID, let index = service.devices.firstIndex(where: { $0.id == deviceID }) { picker.selectItem(at: index) }
        }
        let caps = selected.map(service.capabilities) ?? []
        let ready = selected?.state.isReady == true
        bootButton.isHidden = !caps.contains(.boot) || ready
        shotButton.isEnabled = ready && caps.contains(.screenshot)
        let recording = service.recording != nil
        recordButton.title = recording ? PhoneStrings.stop : PhoneStrings.record
        recordButton.isEnabled = (ready && caps.contains(.recordVideo)) || recording
        sendButton.isEnabled = recording
        notesField.isHidden = !recording
        if recording { status.stringValue = PhoneStrings.recordingHint }
        else if selected?.state == .shutdown { status.stringValue = PhoneStrings.shutDownHint }
        else if ready, !caps.contains(.touch) { status.stringValue = PhoneStrings.stillFrameHint }
    }

    func reloadFrame() {
        guard let device = selected, device.state.isReady else {
            screen.image = nil
            return
        }
        frameLoad?.cancel()
        frameLoad = Task { [weak self, service] in
            do {
                let url = try await service.frame(device.id)
                let data = try await Self.read(url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                self?.screen.image = image
            } catch {
                self?.show(error)
            }
        }
    }

    nonisolated private static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    func show(_ error: any Error) {
        status.stringValue = (error as? PhoneError)?.description ?? error.localizedDescription
    }

    public func select(_ id: PhoneDeviceID) {
        deviceID = id
        syncControls()
        reloadFrame()
    }
}
