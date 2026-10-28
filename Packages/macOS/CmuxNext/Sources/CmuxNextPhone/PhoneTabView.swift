public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups

/// The phone tab: a device picker and action bar over the phone's screen.
/// A booted iOS simulator shows live (its IOSurface, frames from SimulatorKit)
/// and takes clicks, drags and typing. Other phones show a still frame
/// refreshed after every change the service reports; there is no timer.
/// Frames stop while the tab is hidden.
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
    let screen = PhoneScreenView(frame: .zero)
    /// The simulator streaming into ``screen`` now, if any.
    private var liveUDID: String?
    /// This tab's watch of that simulator's frames.
    private var liveWatch: SimulatorKitHID.ScreenWatch?
    /// The Android phone streaming into ``screen`` now, if any.
    private var androidStream: (id: PhoneDeviceID, stream: AndroidScreenStream)?
    /// Where and when a touch on a still frame began (sent as one tap or swipe when it ends).
    private var stillTouch: (point: CGPoint, time: ContinuousClock.Instant)?
    let status = NSTextField(labelWithString: "")
    /// The app's main-thread scheduler: the device follow and the Android stream's frames run as its tasks.
    let mainWork: MainWorkScheduler
    private var observation: VisibleObservation<[Int]>?
    private var frameLoad: Task<Void, Never>?

    /// - Parameters:
    ///   - device: the phone to show first; nil picks the service's default.
    ///   - node: the tab's visibility node: the controls and the frame follow the service only while it shows
    ///     (on show they read once), and the screen streams only then.
    ///   - mainWork: the app's one main-thread scheduler.
    public init(service: PhoneService, device: PhoneDeviceID?, node: VisibilityNode, mainWork: MainWorkScheduler) {
        self.service = service
        deviceID = device
        self.mainWork = mainWork
        super.init(frame: .zero)
        notesField.focusRingType = .none
        build()
        screen.follow(node)
        observation = VisibleObservation(node, owner: "PhoneTabView.devices", on: mainWork) { [service] in
            [service.changeCount, service.devices.count]
        } apply: { [weak self] _ in
            self?.syncControls()
            self?.reloadFrame()
        }
        // main-hop-allow: the task only awaits PhoneService's main-actor reload (simctl and adb run off main); the controls sync in its resume
        Task { [weak self] in await self?.start() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The windows' frame-aligned pointer input (feature `pointerFrameRemoteInput`): the screen's touch
    /// moves reach the phone at most twice per display frame. Nil sends each drag event at once.
    public var pointerFrames: FrameInputCoalescers? {
        get { screen.pointerFrames }
        set { screen.pointerFrames = newValue }
    }

    /// Stops observing; the App calls this when the tab closes.
    public func close() {
        observation?.cancel()
        frameLoad?.cancel()
        stopLive()
        screen.close()
    }

    /// The phone this tab shows, as the tab's restore route (`sim:<udid>`).
    public var route: String? { deviceID?.description }

    /// Notes typed for the running recording and not sent yet: only this view holds them.
    public var hasUnsentNotes: Bool { !notesField.stringValue.isEmpty }

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
            stopLive()
            screen.show(image: nil)
            return
        }
        if startLiveIfPossible(device) { return }
        frameLoad?.cancel()
        // main-hop-allow: the frame is PhoneService's main-actor capture (simctl off main) and its file read is @concurrent; the image shows in its resume
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

    /// The frame file's bytes, read off main.
    @concurrent nonisolated private static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    func show(_ error: any Error) {
        status.stringValue = (error as? PhoneError)?.description ?? error.localizedDescription
    }

    public func select(_ id: PhoneDeviceID) {
        if id != deviceID { stopLive() }
        deviceID = id
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
            liveWatch = try live.startScreen(device.id.raw) { [weak self] surface in self?.screen.show(surface: surface) }
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
            // main-hop-allow: the gesture is PhoneService's main-actor async send (adb or simctl off main); a failure shows in its resume
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
        guard liveUDID != nil else { return }
        if let liveWatch { service.live?.stopScreen(liveWatch) }
        liveWatch = nil
        liveUDID = nil
    }

    /// Streams an Android phone's screen; still frames keep showing under it until the first frame.
    /// Returns false so the still frame loads too (touches go through adb either way).
    private func startAndroidStream(_ device: PhoneDevice) -> Bool {
        guard screen.isOnScreen else { return false }
        if androidStream?.id == device.id { return true }
        stopLive()
        let id = device.id
        // main-hop-allow: the target is PhoneService's main-actor async lookup (adb off main); the stream starts in its resume
        Task { [weak self] in
            guard let self, let target = try? await self.service.androidStreamTarget(id), self.deviceID == id, self.androidStream == nil else { return }
            let stream = AndroidScreenStream(adb: target.adb, serial: target.serial, mainWork: self.mainWork)
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
