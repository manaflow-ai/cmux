import AppKit
import CmuxNextDesign

/// Where cmux answers the host's choosers: the shim in the app (``CEFShimChooserWire``), a recorder in tests.
protocol ChromiumHostChooserWire: AnyObject {
    /// A live color of an open color chooser (each change, as NSColorPanel's continuous updates).
    func chooseColor(token: Int64, color: UInt32)
    /// The person closed the color chooser.
    func endColor(token: Int64)
    func answerDevice(token: Int64, _ answer: ChromiumHostDeviceAnswer)
    func answerDesktopMedia(token: Int64, _ answer: ChromiumHostDesktopMediaAnswer)
}

/// Shows the Chromium Host's color chooser, device choosers and screen-share picker in cmux (host
/// mode, feature `chromiumHostChoosers`, task 228 of plans/cmux-next/chrome-parity/p01-process.md).
/// The host sends each as data (fork API 31's handlers, through the remote shim's local exports) and
/// cmux answers by token, so no chooser of Chromium's opens in the host, which shows no window:
///
/// - `<input type=color>`: the shared NSColorPanel with live colors, as Chrome's ColorChooserMac
///   (chrome/browser/ui/cocoa/color_chooser_mac.mm) drives it: alpha hidden, every change sent, the
///   panel's close ends the chooser.
/// - Web Bluetooth, WebUSB, WebHID and Web Serial: a cmux dialog over the tab with the chooser's rows,
///   updated in place at each state Chromium sends, as Chrome's DeviceChooserContentView follows its
///   ChooserController (chrome/browser/ui/views/device_chooser_content_view.cc).
/// - getDisplayMedia() and chrome.desktopCapture: a cmux dialog with the screens and windows
///   ScreenCaptureKit lists and cmux's Chromium tabs, as Chrome's DesktopMediaPickerViews lists its
///   sources (chrome/browser/ui/views/desktop_capture/desktop_media_picker_views.cc).
///
/// Every request gets exactly one answer unless Chromium ended it first, so a page never waits on a
/// chooser that is not there: a request of a page no pane shows is cancelled at once.
final class ChromiumHostChoosers {
    /// What the choosers show with; tests pass recorders.
    struct Seams {
        /// The view that shows `browser`'s page now, nil when no pane shows it.
        var pageView: @MainActor (Int32) -> NSView? = { _ in nil }
        /// cmux's Chromium tabs a page may share.
        var tabs: @MainActor () -> [ChromiumHostShareTab] = { [] }
        var dialogs: CmuxDialogCenter = .shared
        var colorPanel: any ChromiumHostColorPanelDriving = ChromiumHostColorPanel()
        /// Lists the screens and windows a page may share, then calls back on the main actor.
        var shareSources: @MainActor (@escaping @MainActor (ChromiumHostShareSources) -> Void) -> Void = {
            ChromiumHostShareSources.list(then: $0)
        }
    }

    private struct DeviceRequest {
        var browser: Int32
        var state: ChromiumHostDeviceChooserState
        var view: NSView
        /// The dialog that shows it, what it shows, and the state it was built from.
        var dialog: Int?
        var spec: CmuxDialogSpec?
        var shownState: ChromiumHostDeviceChooserState?
        /// Dialogs presented so far: only the newest one's answer counts.
        var shown = 0
    }

    private struct MediaRequest {
        var browser: Int32
        var request: ChromiumHostDesktopMediaRequest
        var view: NSView
        var dialog: Int?
    }

    // The handlers' events (cmux_cef_shim.h).
    static let colorOpen: Int32 = 0, colorSet: Int32 = 1, colorEnd: Int32 = 2 // CMUX_SHIM_COLOR_CHOOSER_*
    static let deviceUpdate: Int32 = 0, deviceClose: Int32 = 1 // CMUX_SHIM_DEVICE_CHOOSER_*
    static let mediaOpen: Int32 = 0, mediaClose: Int32 = 1 // CMUX_SHIM_DESKTOP_MEDIA_*

    private let wire: any ChromiumHostChooserWire
    private let seams: Seams
    /// The color chooser open now: Chromium has one at a time (a new one ends the last).
    private var color: (browser: Int32, token: Int64)?
    private var devices: [Int64: DeviceRequest] = [:]
    private var media: [Int64: MediaRequest] = [:]
    /// Answers sent so far (`debug.cef` `host_choosers`).
    private var answers = 0

    init(wire: any ChromiumHostChooserWire, seams: Seams = Seams()) {
        self.wire = wire
        self.seams = seams
    }

    /// `debug.cef` `host_choosers`.
    var report: CEFHostChooserReport {
        CEFHostChooserReport(colorOpen: color != nil, deviceChoosers: devices.count, screenShares: media.count, answers: answers)
    }

    // MARK: Color

    /// A `CMUX_SHIM_COLOR_CHOOSER_*` event; `request` is OPEN's struct.
    func colorEvent(_ event: Int32, browser: Int32, token: Int64, color value: UInt32, request: ChromiumHostColorChooserRequest?) {
        switch event {
        case Self.colorOpen: openColor(browser: browser, token: token, color: request?.color ?? value)
        case Self.colorSet: if color?.token == token { seams.colorPanel.show(value) }
        case Self.colorEnd: if color?.token == token { endColor(answer: false) }
        default: break
        }
    }

    private func openColor(browser: Int32, token: Int64, color value: UInt32) {
        // Chromium ends the last chooser itself when a new one opens.
        if color != nil { endColor(answer: false) }
        guard seams.pageView(browser)?.window != nil else {
            answers += 1
            return wire.endColor(token: token)
        }
        color = (browser, token)
        seams.colorPanel.open(value, onColor: { [weak self] picked in
            guard let self, self.color?.token == token else { return }
            self.wire.chooseColor(token: token, color: picked)
        }, onClose: { [weak self] in
            guard let self, self.color?.token == token else { return }
            self.color = nil
            self.answers += 1
            self.wire.endColor(token: token)
        })
    }

    /// The chooser goes; `answer` tells Chromium (the person closed it), else Chromium ended it.
    private func endColor(answer: Bool) {
        guard let open = color else { return }
        color = nil
        seams.colorPanel.close()
        if answer {
            answers += 1
            wire.endColor(token: open.token)
        }
    }

    /// Picks `value` in the open chooser, as the panel would (`debug.cef`). False when none is open.
    func pickColor(_ value: UInt32) -> Bool {
        guard let open = color else { return false }
        seams.colorPanel.show(value)
        wire.chooseColor(token: open.token, color: value)
        return true
    }

    /// Closes the open chooser, as closing the panel would. False when none is open.
    func closeColor() -> Bool {
        guard color != nil else { return false }
        endColor(answer: true)
        return true
    }

    // MARK: Devices

    /// A `CMUX_SHIM_DEVICE_CHOOSER_*` event; `state` is UPDATE's whole chooser.
    func deviceEvent(_ event: Int32, browser: Int32, token: Int64, state: ChromiumHostDeviceChooserState?) {
        switch event {
        case Self.deviceUpdate:
            guard let state else { return answerDevice(token, .init(action: .cancel)) }
            updateDevice(browser: browser, token: token, state: state)
        case Self.deviceClose:
            guard let request = devices.removeValue(forKey: token) else { return }
            if let dialog = request.dialog { seams.dialogs.dismiss(dialog) }
        default: break
        }
    }

    private func updateDevice(browser: Int32, token: Int64, state: ChromiumHostDeviceChooserState) {
        if var request = devices[token] {
            request.state = state
            devices[token] = request
            return showDevice(token)
        }
        guard let view = seams.pageView(browser), view.window != nil else { return answerDevice(token, .init(action: .cancel)) }
        devices[token] = DeviceRequest(browser: browser, state: state, view: view)
        showDevice(token)
    }

    /// Shows the request's state: the open dialog shows it in place, keeping its place in the tab's
    /// dialog queue, the keyboard and the person's chosen devices; the first state presents one.
    private func showDevice(_ token: Int64) {
        guard var request = devices[token] else { return }
        let selected = request.dialog.flatMap { seams.dialogs.record($0)?.values } ?? [:]
        let spec = ChromiumHostChooserDialogs.deviceSpec(request.state, selected: selected, shown: request.shownState)
        request.shownState = request.state
        if spec == request.spec {
            devices[token] = request
            return
        }
        request.spec = spec
        if let dialog = request.dialog, seams.dialogs.update(dialog, spec: spec) {
            devices[token] = request
            return
        }
        request.shown += 1
        let shown = request.shown
        request.dialog = nil
        devices[token] = request
        let dialog = seams.dialogs.present(spec, in: .tab(request.view)) { [weak self] answer in
            self?.deviceAnswered(token, shown: shown, answer)
        }
        if devices[token]?.shown == shown { devices[token]?.dialog = dialog }
    }

    private func deviceAnswered(_ token: Int64, shown: Int, _ answer: CmuxDialogAnswer) {
        // A dialog a newer state replaced, or one of a request Chromium closed, answers nothing.
        guard let request = devices[token], request.shown == shown else { return }
        let reply = ChromiumHostChooserDialogs.deviceAnswer(answer, state: request.state)
        guard reply.action != .rescan else {
            // The chooser stays open and scans again; its next state follows.
            devices[token]?.dialog = nil
            devices[token]?.spec = nil
            devices[token]?.shownState = nil
            devices[token]?.state.refreshing = true
            wire.answerDevice(token: token, reply)
            return showDevice(token)
        }
        devices[token] = nil
        answerDevice(token, reply)
    }

    private func answerDevice(_ token: Int64, _ answer: ChromiumHostDeviceAnswer) {
        answers += 1
        wire.answerDevice(token: token, answer)
    }

    // MARK: Screen share

    /// A `CMUX_SHIM_DESKTOP_MEDIA_*` event; `request` is OPEN's struct.
    func desktopMediaEvent(_ event: Int32, browser: Int32, token: Int64, request: ChromiumHostDesktopMediaRequest?) {
        switch event {
        case Self.mediaOpen:
            guard let request, let view = seams.pageView(browser), view.window != nil else { return answerMedia(token, .cancel) }
            media[token] = MediaRequest(browser: browser, request: request, view: view)
            seams.shareSources { [weak self] sources in self?.showMedia(token, sources: sources) }
        case Self.mediaClose:
            guard let request = media.removeValue(forKey: token) else { return }
            if let dialog = request.dialog { seams.dialogs.dismiss(dialog) }
        default: break
        }
    }

    private func showMedia(_ token: Int64, sources: ChromiumHostShareSources) {
        // Chromium dropped the request while the sources were listed.
        guard let request = media[token] else { return }
        guard request.view.window != nil else {
            media[token] = nil
            return answerMedia(token, .cancel)
        }
        let tabs = seams.tabs().filter { $0.browser != request.browser }
        let spec = ChromiumHostChooserDialogs.shareSpec(request.request, sources: sources, tabs: tabs)
        let dialog = seams.dialogs.present(spec, in: .tab(request.view)) { [weak self] answer in
            guard let self, let request = self.media.removeValue(forKey: token) else { return }
            self.answerMedia(token, ChromiumHostChooserDialogs.shareAnswer(answer, request: request.request))
        }
        if media[token] != nil { media[token]?.dialog = dialog }
    }

    private func answerMedia(_ token: Int64, _ answer: ChromiumHostDesktopMediaAnswer) {
        answers += 1
        wire.answerDesktopMedia(token: token, answer)
    }

    // MARK: Lifetime

    /// The page closed (BEFORE_CLOSE): Chromium ended its requests; their dialogs and panel go unanswered.
    func ownerClosed(_ browser: Int32) {
        if color?.browser == browser { endColor(answer: false) }
        for (token, request) in devices where request.browser == browser {
            devices[token] = nil
            if let dialog = request.dialog { seams.dialogs.dismiss(dialog) }
        }
        for (token, request) in media where request.browser == browser {
            media[token] = nil
            if let dialog = request.dialog { seams.dialogs.dismiss(dialog) }
        }
    }

    /// The host ended: its requests went with it, and nothing can be answered.
    func hostEnded() {
        for browser in Set(devices.values.map(\.browser)).union(media.values.map(\.browser)) { ownerClosed(browser) }
        endColor(answer: false)
    }
}

/// `debug.cef` `host_choosers`: the host's choosers cmux shows now.
public struct CEFHostChooserReport: Equatable, Sendable {
    /// The color panel answers an open `<input type=color>`.
    public let colorOpen: Bool
    /// Device chooser and screen-share dialogs open now.
    public let deviceChoosers: Int
    public let screenShares: Int
    /// Answers sent to the host so far.
    public let answers: Int
}
