public import AppKit
import CmuxNextCompat

/// The phone tab: a device picker and action bar over the phone's screen.
/// A booted iOS simulator shows live (its IOSurface, frames from SimulatorKit)
/// and takes clicks, drags, scrolling and typing. Other phones show a still
/// frame refreshed after every change the service reports; there is no
/// timer. Frames stop while the tab is hidden.
///
/// When this Mac has no phone it can show (no Xcode, no iOS runtime, no
/// simulator), the setup screen (``PhoneSetupView``) takes the screen's place
/// and walks the user through what to install, checking again by itself
/// when the app becomes active.
@MainActor
public final class PhoneTabView: NSView {
    let service: PhoneService
    private(set) var deviceID: PhoneDeviceID?
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let bootButton = NSButton()
    let shutdownButton = NSButton()
    let shotButton = NSButton()
    let recordButton = NSButton()
    let sendButton = NSButton()
    let notesField = NSTextField()
    let screen = PhoneScreenView(frame: .zero)
    let setupView = PhoneSetupView(frame: .zero)
    /// The last action's outcome or failure, shown in the status line until the next action or phone change.
    private(set) var notice: PhoneErrorText?
    /// True after the user picked "Set Up iPhone Simulators…" while other phones exist.
    var forceSetup = false
    /// The simulator streaming into ``screen`` now, if any.
    private var liveUDID: String?
    /// The Android phone streaming into ``screen`` now, if any.
    private var androidStream: (id: PhoneDeviceID, stream: AndroidScreenStream)?
    /// Where and when a touch on a still frame began (sent as one tap or swipe when it ends).
    private var stillTouch: (point: CGPoint, time: ContinuousClock.Instant)?
    let status = NSTextField(labelWithString: "")
    private var observation: Task<Void, Never>?
    private var activation: Task<Void, Never>?
    private var frameLoad: Task<Void, Never>?

    /// - Parameter device: the phone to show first; nil picks the service's default.
    public init(service: PhoneService, device: PhoneDeviceID?) {
        self.service = service
        deviceID = device
        super.init(frame: .zero)
        notesField.focusRingType = .none
        build()
        observation = Task { [weak self] in
            guard let service = self?.service else { return }
            for await _ in ObservationStream({ (service.changeCount, service.devices.count, service.setup.status,
                                                 service.setup.activity, service.setup.failure) }) {
                guard let self else { return }
                self.syncControls()
                self.reloadFrame()
            }
        }
        // Coming back to cmux (from the App Store, Xcode or Android Studio) checks the setup again.
        activation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                if self.showsSetup { await self.recheck() }
            }
        }
        // task-owner: the tab's first load; it only reads the device list and updates this view.
        Task { [weak self] in await self?.start() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stops observing; the App calls this when the tab closes.
    public func close() {
        observation?.cancel()
        activation?.cancel()
        frameLoad?.cancel()
        stopLive()
        screen.close()
    }

    /// The phone this tab shows, as the tab's restore route (`sim:<udid>`).
    public var route: String? { deviceID?.description }

    /// The first load: setup state, the device list and the phone to show. With no phone at all
    /// the setup screen (or the "no phones" hint) shows; that is not an error.
    func start() async {
        if service.setup.isAvailable { await service.setup.refresh() }
        do {
            try await service.reload()
        } catch {
            show(error)
        }
        if deviceID == nil, service.devices.contains(where: \.isUsable) { deviceID = try? await service.defaultDevice().id }
        syncControls()
        reloadFrame()
    }

    /// Checks the setup and the device list again (the setup screen's Check Again, and app activation).
    func recheck() async {
        await service.setup.refresh()
        try? await service.reload()
        if selected == nil, service.devices.contains(where: \.isUsable) { deviceID = try? await service.defaultDevice().id }
        syncControls()
        reloadFrame()
    }

    /// True while the setup screen takes the phone's place: setup can run here, it is not done,
    /// and there is no phone to show (or the user asked for setup).
    var showsSetup: Bool {
        guard service.setup.isAvailable, service.setup.status?.step != .ready else { return false }
        return forceSetup || !service.devices.contains(where: \.isUsable)
    }

    var selected: PhoneDevice? { service.devices.first { $0.id == deviceID } }

    /// Picker items that run a command instead of picking a phone.
    static let refreshItem = "cmux:refresh", setupItem = "cmux:setup"

    func syncControls() {
        syncPicker()
        let caps = selected.map(service.capabilities) ?? []
        let ready = selected?.state.isReady == true
        let busy = selected.flatMap { service.busy[$0.id] }
        bootButton.isHidden = !caps.contains(.boot) || selected?.state != .shutdown || busy != nil
        shutdownButton.isHidden = !caps.contains(.boot) || !ready || busy != nil
        shotButton.isEnabled = ready && caps.contains(.screenshot)
        let recording = service.recording != nil
        recordButton.title = recording ? PhoneStrings.stop : PhoneStrings.record
        recordButton.isEnabled = (ready && caps.contains(.recordVideo)) || recording
        sendButton.isEnabled = recording
        notesField.isHidden = !recording
        status.stringValue = statusText(caps: caps, busy: busy, recording: recording)
        status.toolTip = notice?.detail
        let setup = showsSetup
        setupView.isHidden = !setup
        screen.isHidden = setup
        if setup {
            setupView.show(PhoneSetupViewState(status: service.setup.status, activity: service.setup.activity, failure: service.setup.failure))
        }
    }

    /// The status line, derived from the phone's state each time (so it never keeps an old "Booting…").
    private func statusText(caps: PhoneCapabilities, busy: PhoneBusy?, recording: Bool) -> String {
        if let notice { return notice.message }
        if recording { return PhoneStrings.recordingHint }
        guard let device = selected else {
            return service.devices.contains(where: \.isUsable) || showsSetup ? "" : PhoneStrings.noPhones
        }
        switch busy {
        case .booting?: return PhoneStrings.bootingHint
        case .shuttingDown?: return PhoneStrings.shuttingDown
        case nil: break
        }
        switch device.state {
        case .unavailable: return PhoneStrings.unavailableHint
        case .booting: return PhoneStrings.bootingHint
        case .shutdown: return PhoneStrings.shutDownHint
        case .disconnected: return ""
        case .ready: return caps.contains(.touch) ? "" : PhoneStrings.stillFrameHint
        }
    }

    private func syncPicker() {
        picker.removeAllItems()
        let menu = picker.menu
        if service.devices.isEmpty {
            picker.addItem(withTitle: PhoneStrings.noPhonesShort)
            picker.lastItem?.isEnabled = false
        }
        for device in service.devices {
            let title = "\(device.name) · \(device.osVersion)" + (device.mode == .device ? " · \(PhoneStrings.realDevice)" : "")
            picker.addItem(withTitle: title)
            picker.lastItem?.representedObject = device.id.description
            picker.lastItem?.isEnabled = device.isUsable
        }
        menu?.addItem(.separator())
        picker.addItem(withTitle: PhoneStrings.refresh)
        picker.lastItem?.representedObject = Self.refreshItem
        if service.setup.isAvailable, let step = service.setup.status?.step, step != .ready {
            picker.addItem(withTitle: PhoneStrings.setUpSimulators)
            picker.lastItem?.representedObject = Self.setupItem
        }
        picker.isEnabled = true
        if let deviceID, let index = service.devices.firstIndex(where: { $0.id == deviceID }) {
            picker.selectItem(at: index)
        } else {
            picker.selectItem(at: 0)
        }
    }

    func reloadFrame() {
        guard let device = selected, device.state.isReady else {
            stopLive()
            screen.show(image: nil)
            return
        }
        if startLiveIfPossible(device) { return }
        frameLoad?.cancel()
        frameLoad = Task { [weak self, service] in
            do {
                let url = try await service.frame(device.id)
                let data = try await Self.read(url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                self?.screen.show(image: image)
            } catch {
                self?.show(error)
            }
        }
    }

    nonisolated private static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    /// Shows a failure in plain words; the tool's own text is the tooltip.
    func show(_ error: any Error) {
        tell(PhoneErrorText(error))
    }

    /// Shows `text` in the status line until the next action or phone change.
    func tell(_ text: PhoneErrorText?) {
        notice = text
        status.stringValue = text?.message ?? status.stringValue
        status.toolTip = text?.detail
        if text == nil { syncControls() }
    }

    public func select(_ id: PhoneDeviceID) {
        if id != deviceID { stopLive() }
        deviceID = id
        notice = nil
        forceSetup = false
        syncControls()
        reloadFrame()
    }
}

extension PhoneTabView {
    /// Wires the screen's input and visibility to the service.
    func connectScreen() {
        screen.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            if visible { self.reloadFrame() } else { self.stopLive() }
        }
        screen.onTouch = { [weak self] phase, point in
            guard let self else { return }
            if let udid = self.liveUDID, let live = self.service.live {
                do { try live.touchNow(phase, x: point.x, y: point.y, udid: udid) } catch { self.show(error) }
                return
            }
            self.stillFrameTouch(phase, point)
        }
        screen.onKey = { [weak self] code, down in
            guard let self, let udid = self.liveUDID, let live = self.service.live,
                  let usage = PhoneKeyboard().usage(forMacKeyCode: code) else { return false }
            do { try live.keyNow(usage, down: down, udid: udid) } catch { self.show(error) }
            return true
        }
    }

    /// Streams a booted simulator into the screen while the tab is visible. False when it cannot.
    func startLiveIfPossible(_ device: PhoneDevice) -> Bool {
        if device.mode.isAndroid { return startAndroidStream(device) }
        guard device.mode == .simulator, screen.isOnScreen, let live = service.live else { return false }
        if liveUDID == device.id.raw { return true }
        stopLive()
        do {
            try live.startScreen(device.id.raw) { [weak self] surface in self?.screen.show(surface: surface) }
            liveUDID = device.id.raw
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// A still frame (Android, or iOS without SimulatorKit) takes the whole gesture at once when it ends.
    private func stillFrameTouch(_ phase: PhoneTouch.Phase, _ point: CGPoint) {
        guard let device = selected, service.capabilities(device).contains(.touch) else { return }
        switch phase {
        case .began: stillTouch = (point, .now)
        case .moved: break
        case .ended:
            guard let start = stillTouch else { return }
            stillTouch = nil
            let elapsed = ContinuousClock.now - start.time
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let id = device.id
            Task { [weak self] in
                guard let self else { return }
                do { try await self.service.touch(from: start.point, to: point, seconds: seconds, on: id) } catch { self.show(error) }
            }
        }
    }

    func stopLive() {
        if let android = androidStream {
            android.stream.stop()
            androidStream = nil
            screen.endVideo()
        }
        guard let udid = liveUDID else { return }
        service.live?.stopScreen(udid)
        liveUDID = nil
    }

    /// Streams an Android phone's screen; still frames keep showing under it until the first frame.
    /// Returns false so the still frame loads too (touches go through adb either way).
    private func startAndroidStream(_ device: PhoneDevice) -> Bool {
        guard screen.isOnScreen else { return false }
        if androidStream?.id == device.id { return true }
        stopLive()
        let id = device.id
        Task { [weak self] in
            guard let self, let target = try? await self.service.androidStreamTarget(id), self.deviceID == id, self.androidStream == nil else { return }
            let stream = AndroidScreenStream(adb: target.adb, serial: target.serial)
            stream.onSample = { [weak self] sample in self?.screen.show(sample: sample) }
            stream.onError = { [weak self] error in
                self?.show(error)
                self?.screen.endVideo()
            }
            self.androidStream = (id, stream)
            stream.start()
        }
        return false
    }
}
