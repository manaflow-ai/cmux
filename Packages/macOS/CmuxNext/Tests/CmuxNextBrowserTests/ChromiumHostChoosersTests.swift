import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The host's color chooser, device choosers and screen-share picker in cmux: each
/// request gets one answer by token, Chromium's own end gets none, and a page no pane shows never waits.
@MainActor
@Suite struct ChromiumHostChoosersTests {
    @MainActor
    final class RecordingWire: ChromiumHostChooserWire {
        var colors: [(Int64, UInt32)] = []
        var colorEnds: [Int64] = []
        var devices: [(Int64, ChromiumHostDeviceAnswer)] = []
        var media: [(Int64, ChromiumHostDesktopMediaAnswer)] = []
        func chooseColor(token: Int64, color: UInt32) { colors.append((token, color)) }
        func endColor(token: Int64) { colorEnds.append(token) }
        func answerDevice(token: Int64, _ answer: ChromiumHostDeviceAnswer) { devices.append((token, answer)) }
        func answerDesktopMedia(token: Int64, _ answer: ChromiumHostDesktopMediaAnswer) { media.append((token, answer)) }
    }

    @MainActor
    final class RecordingPanel: ChromiumHostColorPanelDriving {
        var shown: [UInt32] = []
        var opened = 0
        var closed = 0
        var onColor: ((UInt32) -> Void)?
        var onClose: (() -> Void)?
        func open(_ color: UInt32, onColor: @escaping (UInt32) -> Void, onClose: @escaping () -> Void) {
            opened += 1
            shown.append(color)
            self.onColor = onColor
            self.onClose = onClose
        }
        func show(_ color: UInt32) { shown.append(color) }
        func close() {
            closed += 1
            onColor = nil
            onClose = nil
        }
    }

    struct Rig {
        let wire = RecordingWire()
        let panel = RecordingPanel()
        let host = CmuxDialogHeadlessHost()
        let dialogs: CmuxDialogCenter
        let window: NSWindow
        let page: NSView
        let choosers: ChromiumHostChoosers
        /// The pending screen and window listings' callbacks.
        let listings: Listings

        @MainActor
        final class Listings {
            var pending: [@MainActor (ChromiumHostShareSources) -> Void] = []
        }

        init(pageBrowser: Int32 = 3) {
            _ = NSApplication.shared
            dialogs = CmuxDialogCenter(host: host)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView?.addSubview(page)
            let listings = Listings()
            self.listings = listings
            var seams = ChromiumHostChoosers.Seams()
            seams.pageView = { [page] browser in browser == pageBrowser ? page : nil }
            seams.tabs = { [ChromiumHostShareTab(browser: 3, title: "Asking"), ChromiumHostShareTab(browser: 9, title: "Docs")] }
            seams.dialogs = dialogs
            seams.colorPanel = panel
            seams.shareSources = { listings.pending.append($0) }
            choosers = ChromiumHostChoosers(wire: wire, seams: seams)
        }

        /// The newest visible dialog with `identifier`.
        func dialog(_ identifier: String) -> CmuxDialogCenter.Record? {
            dialogs.records.last { $0.spec.identifier == identifier && $0.visible }
        }

        func list(_ sources: ChromiumHostShareSources) {
            let pending = listings.pending
            listings.pending = []
            for call in pending { call(sources) }
        }
    }

    func deviceState(token: Int64 = 51, options: [String] = [], initialized: Bool = true, multiple: Bool = false,
                     rescan: Bool = false) -> ChromiumHostDeviceChooserState {
        ChromiumHostDeviceChooserState(
            token: token, origin: "https://usb.test", title: "usb.test wants to connect", noOptionsText: "No devices",
            okLabel: "Connect", showsSignalStrength: false, offersRescan: rescan, allowsMultiple: multiple, initialized: initialized,
            refreshing: false, adapterEnabled: true, adapterAuthorized: true, bothButtonsAlwaysEnabled: false,
            options: options.map { .init(name: $0, signalStrength: -1, connected: false, paired: false) })
    }

    // MARK: Color

    /// `<input type=color>`: the panel opens with the input's color, each pick goes to the page, the page's
    /// own value shows, and the panel's close ends the chooser once.
    @Test func theColorPanelAnswersLive() {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.colorEvent(ChromiumHostChoosers.colorOpen, browser: 3, token: 41, color: 0xFF00_0000,
                                request: ChromiumHostColorChooserRequest(token: 41, color: 0xFF11_2233, suggestions: []))
        #expect(rig.panel.opened == 1 && rig.panel.shown == [0xFF11_2233])
        #expect(rig.choosers.report.colorOpen)
        rig.panel.onColor?(0xFF40_5060)
        rig.panel.onColor?(0xFF70_8090)
        #expect(rig.wire.colors.map(\.1) == [0xFF40_5060, 0xFF70_8090] && rig.wire.colors.allSatisfy { $0.0 == 41 })
        rig.choosers.colorEvent(ChromiumHostChoosers.colorSet, browser: 0, token: 41, color: 0xFF00_00FF, request: nil)
        #expect(rig.panel.shown.last == 0xFF00_00FF)
        #expect(rig.wire.colors.count == 2, "the page's own value is not the person's pick")
        rig.panel.onClose?()
        #expect(rig.wire.colorEnds == [41] && !rig.choosers.report.colorOpen)
        rig.choosers.colorEvent(ChromiumHostChoosers.colorEnd, browser: 0, token: 41, color: 0, request: nil)
        #expect(rig.wire.colorEnds == [41], "Chromium's end after cmux's sends nothing")
    }

    /// Chromium's end closes the panel with no answer; a chooser of a page no pane shows ends at once.
    @Test func theColorChooserEndsWithoutAPage() {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.colorEvent(ChromiumHostChoosers.colorOpen, browser: 3, token: 42, color: 0xFF00_0000, request: nil)
        rig.choosers.colorEvent(ChromiumHostChoosers.colorEnd, browser: 0, token: 42, color: 0, request: nil)
        #expect(rig.panel.closed == 1 && rig.wire.colorEnds.isEmpty)
        rig.choosers.colorEvent(ChromiumHostChoosers.colorOpen, browser: 99, token: 43, color: 0xFF00_0000, request: nil)
        #expect(rig.panel.opened == 1 && rig.wire.colorEnds == [43])
    }

    @Test func colorsConvertAsSRGB() {
        #expect(ChromiumHostColorPanel.argb(ChromiumHostColorPanel.color(0xFF12_3456)) == 0xFF12_3456)
        #expect(ChromiumHostColorPanel.argb(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)) == 0xFFFF_0000)
    }

    // MARK: Devices

    /// A chooser searches, then lists its rows in the same token: the dialog shows each state in place,
    /// answers nothing on the way, and Connect selects the chosen row.
    @Test func aDeviceChooserFollowsItsStateAndSelects() throws {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 51, state: deviceState(initialized: false))
        let searching = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(searching.spec.lines == [ChromiumHostChooserDialogs.Strings.searching])
        #expect(searching.spec.buttons.map(\.id) == ["cancel"], "no Connect with nothing to connect")
        #expect(searching.spec.origin == "https://usb.test" && searching.spec.title == "usb.test wants to connect")

        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 51, state: deviceState(options: ["Key", "Pad"]))
        let listed = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(listed.id == searching.id && rig.dialogs.records.count == 1, "the open dialog shows the rows")
        #expect(rig.wire.devices.isEmpty, "the update answered nothing")
        #expect(listed.spec.buttons.map(\.id) == ["cancel", "connect"])
        // The same state again keeps the dialog.
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 51, state: deviceState(options: ["Key", "Pad"]))
        #expect(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier)?.id == listed.id)

        #expect(rig.dialogs.setValue(.text("1"), for: ChromiumHostChooserDialogs.deviceField, in: listed.id))
        #expect(rig.dialogs.press(listed.id, button: "connect"))
        #expect(rig.wire.devices.count == 1 && rig.wire.devices[0].0 == 51)
        #expect(rig.wire.devices[0].1 == ChromiumHostDeviceAnswer(action: .select, rows: [1]))
        #expect(rig.choosers.report.deviceChoosers == 0)
    }

    /// No row is chosen until the person chooses one, as Chrome's chooser opens with no table selection:
    /// Connect or Return with no choice sends no SELECT.
    @Test func noDeviceIsChosenForThePerson() throws {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 52, state: deviceState(token: 52, options: ["Key", "Pad"]))
        let dialog = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        guard case .choice(_, _, let options, let selected)? = dialog.spec.fields.first else {
            Issue.record("no device choice")
            return
        }
        #expect(options.map(\.value) == ["", "0", "1"] && selected == "")
        #expect(dialog.values[ChromiumHostChooserDialogs.deviceField] == .text(""))
        #expect(rig.dialogs.key(.return, in: dialog.id))
        #expect(rig.wire.devices.map(\.1) == [ChromiumHostDeviceAnswer(action: .cancel)])

        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 53, state: deviceState(token: 53, options: ["Key"]))
        let second = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(rig.dialogs.press(second.id, button: "connect"))
        #expect(rig.wire.devices.last?.1 == ChromiumHostDeviceAnswer(action: .cancel))
        #expect(!rig.wire.devices.contains { $0.1.action == .select })
    }

    /// The chosen row follows its device when a row above it goes (Chromium's OnOptionRemoved), and a
    /// device that goes leaves nothing chosen: Connect never answers a device the person did not choose.
    @Test func theChosenRowFollowsItsDevice() throws {
        let rig = Rig()
        defer { rig.window.close() }
        let field = ChromiumHostChooserDialogs.deviceField
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 54,
                                 state: deviceState(token: 54, options: ["A", "B", "C", "D"]))
        let dialog = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(rig.dialogs.setValue(.text("2"), for: field, in: dialog.id), "the person chooses C")
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 54,
                                 state: deviceState(token: 54, options: ["B", "C", "D"]))
        #expect(rig.dialogs.record(dialog.id)?.values[field] == .text("1"), "C moved up one row")
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 54,
                                 state: deviceState(token: 54, options: ["B", "D"]))
        #expect(rig.dialogs.record(dialog.id)?.values[field] == .text(""), "C went: nothing is chosen")
        #expect(rig.dialogs.press(dialog.id, button: "connect"))
        #expect(rig.wire.devices.map(\.1) == [ChromiumHostDeviceAnswer(action: .cancel)])

        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 55,
                                 state: deviceState(token: 55, options: ["A", "B", "C"], multiple: true))
        let multiple = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        rig.dialogs.setValue(.bool(true), for: "device.2", in: multiple.id)
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 55,
                                 state: deviceState(token: 55, options: ["B", "C"], multiple: true))
        let values = try #require(rig.dialogs.record(multiple.id)?.values)
        #expect(values["device.0"] == .bool(false) && values["device.1"] == .bool(true))
        rig.dialogs.press(multiple.id, button: "connect")
        #expect(rig.wire.devices.last?.1 == ChromiumHostDeviceAnswer(action: .select, rows: [1]))

        // A name on two rows says nothing of which device the person chose.
        let shown = deviceState(options: ["Pad", "Pad", "Key"])
        #expect(ChromiumHostChooserDialogs.keptRows([field: .text("1")], shown: shown, in: deviceState(options: ["Pad", "Key"])).isEmpty)
        #expect(ChromiumHostChooserDialogs.keptRows([field: .text("2")], shown: shown, in: deviceState(options: ["Key"])) == [0])
    }

    /// Another dialog waiting in the same tab (a JS alert) stays behind the chooser while its rows change.
    @Test func anUpdateKeepsTheChooserInFrontOfTheTabsQueue() throws {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 56, state: deviceState(token: 56, initialized: false))
        let chooser = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        var alerted = false
        let alert = rig.dialogs.present(CmuxDialogSpec(title: "Alert", buttons: [.ok()], identifier: "alert"), in: .tab(rig.page)) { _ in
            alerted = true
        }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 56, state: deviceState(token: 56, options: ["A"]))
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 56, state: deviceState(token: 56, options: ["A", "B"]))
        #expect(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier)?.id == chooser.id)
        #expect(rig.dialogs.record(alert)?.visible == false && !alerted)
        #expect(rig.dialogs.records.map(\.id) == [chooser.id, alert])
        #expect(rig.wire.devices.isEmpty)
    }

    /// Chromium's close takes the dialog down unanswered; a tab that goes closes the chooser; Scan Again
    /// keeps it open; a page no pane shows is cancelled at once.
    @Test func aDeviceChooserEndsEachWay() throws {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 61, state: deviceState(token: 61, options: ["A"]))
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceClose, browser: 0, token: 61, state: nil)
        #expect(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier) == nil && rig.wire.devices.isEmpty)

        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 62, state: deviceState(token: 62, rescan: true))
        let first = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(first.spec.buttons.map(\.id) == ["cancel", "rescan"])
        rig.dialogs.press(first.id, button: "rescan")
        #expect(rig.wire.devices.map(\.1.action) == [.rescan])
        let again = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier), "the chooser stays open")
        #expect(again.spec.lines == [ChromiumHostChooserDialogs.Strings.searching])
        rig.dialogs.dismiss(again.id)
        #expect(rig.wire.devices.map(\.1.action) == [.rescan, .close])

        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 99, token: 63, state: deviceState(token: 63))
        #expect(rig.wire.devices.last?.0 == 63 && rig.wire.devices.last?.1.action == .cancel)
    }

    /// Several rows may be chosen: one check each; a Connect with none checked is a cancel.
    @Test func aMultipleChooserChecksRows() throws {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 71,
                                 state: deviceState(token: 71, options: ["A", "B", "C"], multiple: true))
        let dialog = try #require(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier))
        #expect(dialog.spec.fields.compactMap(\.id) == ["device.0", "device.1", "device.2"])
        rig.dialogs.setValue(.bool(true), for: "device.0", in: dialog.id)
        rig.dialogs.setValue(.bool(true), for: "device.2", in: dialog.id)
        rig.dialogs.press(dialog.id, button: "connect")
        #expect(rig.wire.devices.last?.1 == ChromiumHostDeviceAnswer(action: .select, rows: [0, 2]))

        let none = ChromiumHostChooserDialogs.deviceAnswer(CmuxDialogAnswer(button: "connect", role: .default),
                                                           state: deviceState(options: ["A"], multiple: true))
        #expect(none.action == .cancel)
    }

    // MARK: Screen share

    /// getDisplayMedia: the picker lists screens, windows, this tab and the other tabs, the page's preferred
    /// kind first; Share answers the chosen source with audio.
    @Test func theSharePickerListsAndAnswers() throws {
        let rig = Rig()
        defer { rig.window.close() }
        let request = ChromiumHostDesktopMediaRequest(token: 81, appName: "share.test", sources: [.screen, .window, .tab, .currentTab],
                                                      preferred: .window, requestsAudio: true)
        rig.choosers.desktopMediaEvent(ChromiumHostChoosers.mediaOpen, browser: 3, token: 81, request: request)
        #expect(rig.dialog(ChromiumHostChooserDialogs.shareIdentifier) == nil, "the picker waits for the listing")
        rig.list(ChromiumHostShareSources(screens: [.init(id: 1, name: "Built-in")], windows: [.init(id: 77, title: "Notes", app: "Notes")],
                                          listed: true))
        let dialog = try #require(rig.dialog(ChromiumHostChooserDialogs.shareIdentifier))
        guard case .choice(_, _, let options, let selected)? = dialog.spec.fields.first else {
            Issue.record("no source choice")
            return
        }
        #expect(options.map(\.value) == ["window:77", "screen:1", "current", "tab:9"], "the asking tab is This tab, not a tab row")
        #expect(selected == "window:77")
        #expect(dialog.spec.fields.count == 2 && dialog.spec.lines.isEmpty)
        rig.dialogs.setValue(.text("screen:1"), for: ChromiumHostChooserDialogs.sourceField, in: dialog.id)
        rig.dialogs.press(dialog.id, button: "share")
        #expect(rig.wire.media.count == 1 && rig.wire.media[0].0 == 81)
        #expect(rig.wire.media[0].1 == ChromiumHostDesktopMediaAnswer(sourceType: .screen, nativeID: 1, audio: true))
    }

    /// Chromium drops the request while the sources are listed: nothing shows and nothing answers. A
    /// cancel answers no source; without the recording permission the picker says so.
    @Test func theSharePickerEndsEachWay() throws {
        let rig = Rig()
        defer { rig.window.close() }
        let request = ChromiumHostDesktopMediaRequest(token: 82, appName: "share.test", sources: [.screen, .tab], preferred: [],
                                                      requestsAudio: false)
        rig.choosers.desktopMediaEvent(ChromiumHostChoosers.mediaOpen, browser: 3, token: 82, request: request)
        rig.choosers.desktopMediaEvent(ChromiumHostChoosers.mediaClose, browser: 0, token: 82, request: nil)
        rig.list(.none)
        #expect(rig.dialog(ChromiumHostChooserDialogs.shareIdentifier) == nil && rig.wire.media.isEmpty)

        rig.choosers.desktopMediaEvent(ChromiumHostChoosers.mediaOpen, browser: 3, token: 83, request: request)
        rig.list(.none)
        let dialog = try #require(rig.dialog(ChromiumHostChooserDialogs.shareIdentifier))
        #expect(dialog.spec.lines == [ChromiumHostChooserDialogs.Strings.recordingPermission])
        rig.dialogs.press(dialog.id, button: "cancel")
        #expect(rig.wire.media.map(\.1) == [.cancel])

        rig.choosers.desktopMediaEvent(ChromiumHostChoosers.mediaOpen, browser: 99, token: 84, request: request)
        #expect(rig.wire.media.last?.0 == 84 && rig.wire.media.last?.1 == .cancel && rig.listings.pending.isEmpty)
    }

    /// A tab answer names its browser; a source the request does not allow is a cancel.
    @Test func shareAnswersKeepToTheRequest() {
        let request = ChromiumHostDesktopMediaRequest(token: 1, appName: "", sources: [.tab], preferred: [], requestsAudio: false)
        func answer(_ value: String) -> ChromiumHostDesktopMediaAnswer {
            ChromiumHostChooserDialogs.shareAnswer(
                CmuxDialogAnswer(button: "share", role: .default, values: [ChromiumHostChooserDialogs.sourceField: .text(value)]), request: request)
        }
        #expect(answer("tab:9") == ChromiumHostDesktopMediaAnswer(sourceType: .tab, tabBrowser: 9))
        #expect(answer("screen:1") == .cancel)
        #expect(answer("tab:x") == .cancel)
    }

    // MARK: Lifetime

    /// The page's close and the host's end take every chooser down unanswered.
    @Test func closeAndHostEndTakeChoosersDown() {
        let rig = Rig()
        defer { rig.window.close() }
        rig.choosers.colorEvent(ChromiumHostChoosers.colorOpen, browser: 3, token: 91, color: 0, request: nil)
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 92, state: deviceState(token: 92))
        rig.choosers.ownerClosed(3)
        #expect(rig.panel.closed == 1 && rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier) == nil)
        rig.choosers.deviceEvent(ChromiumHostChoosers.deviceUpdate, browser: 3, token: 93, state: deviceState(token: 93))
        rig.choosers.hostEnded()
        #expect(rig.dialog(ChromiumHostChooserDialogs.deviceIdentifier) == nil)
        #expect(rig.wire.devices.isEmpty && rig.wire.colorEnds.isEmpty)
    }

    // MARK: Fork structs

    /// The fork's cmux_device_chooser_t read at host_choosers.h's LP64 offsets; an older struct reads as none.
    @Test func theDeviceStructReadsAtTheForksOffsets() throws {
        // SAFETY (this test): the buffers live until the defers; every store is inside them, at host_choosers.h's offsets.
        let name = unsafe strdup("Pad")
        let title = unsafe strdup("t")
        defer { unsafe free(name); unsafe free(title) }
        let row = unsafe UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        let state = unsafe UnsafeMutableRawPointer.allocate(byteCount: 96, alignment: 8)
        defer { unsafe row.deallocate(); unsafe state.deallocate() }
        unsafe row.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        unsafe state.initializeMemory(as: UInt8.self, repeating: 0, count: 96)
        unsafe row.storeBytes(of: UnsafePointer(name), as: UnsafePointer<CChar>?.self)
        unsafe row.storeBytes(of: 3, toByteOffset: 8, as: Int32.self)
        unsafe row.storeBytes(of: 1, toByteOffset: 16, as: Int32.self)
        unsafe state.storeBytes(of: 96, as: Int32.self)
        unsafe state.storeBytes(of: 77, toByteOffset: 8, as: Int64.self)
        unsafe state.storeBytes(of: UnsafePointer(title), toByteOffset: 24, as: UnsafePointer<CChar>?.self)
        unsafe state.storeBytes(of: 1, toByteOffset: 52, as: Int32.self)
        unsafe state.storeBytes(of: 1, toByteOffset: 68, as: Int32.self)
        unsafe state.storeBytes(of: UnsafeRawPointer(row), toByteOffset: 80, as: UnsafeRawPointer?.self)
        unsafe state.storeBytes(of: 1, toByteOffset: 88, as: Int32.self)
        let address = unsafe UInt(bitPattern: state)
        let read = try #require(ChromiumHostDeviceChooserState(forkAddress: address))
        #expect(read.token == 77 && read.title == "t" && read.origin.isEmpty && read.offersRescan && read.adapterEnabled)
        #expect(!read.adapterAuthorized && !read.allowsMultiple)
        #expect(read.options == [.init(name: "Pad", signalStrength: 3, connected: false, paired: true)])
        unsafe state.storeBytes(of: 64, as: Int32.self)
        #expect(ChromiumHostDeviceChooserState(forkAddress: address) == nil)
        #expect(ChromiumHostDeviceChooserState(forkAddress: 0) == nil)
    }

    @Test func theColorChooserSwitchGoesWithTheHandler() {
        let switches = CEFSwitches.current(forkAPIVersion: 31, embedderColorChooser: true, bundleIdentifier: nil, environment: [:])
        #expect(switches.arguments.contains(CEFSwitches.embedderColorChooserArgument))
        let without = CEFSwitches.current(forkAPIVersion: 31, bundleIdentifier: nil, environment: [:])
        #expect(!without.arguments.contains(CEFSwitches.embedderColorChooserArgument))
    }
}
