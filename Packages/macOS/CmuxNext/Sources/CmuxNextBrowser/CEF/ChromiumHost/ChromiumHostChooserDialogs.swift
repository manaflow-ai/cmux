import CmuxNextDesign
import Foundation

/// cmux's answer to a device chooser (`cmux_shim_device_chooser_answer`).
nonisolated struct ChromiumHostDeviceAnswer: Equatable, Sendable {
    /// `CMUX_DEVICE_CHOOSER_*`.
    nonisolated enum Action: Int32, Sendable {
        case select = 0
        case cancel = 1
        /// Closed with no choice (the tab or window went away).
        case close = 2
        case rescan = 3
    }

    var action: Action
    /// The chosen rows' indices (SELECT; none for the Bluetooth scanning prompt's Allow).
    var rows: [Int] = []
}

/// cmux's answer to a screen-share picker (`cmux_shim_desktop_media_answer`).
nonisolated struct ChromiumHostDesktopMediaAnswer: Equatable, Sendable {
    /// One source bit, empty to cancel.
    var sourceType: ChromiumHostDesktopMediaRequest.Sources
    /// The CGDirectDisplayID (screen) or CGWindowID (window), else 0.
    var nativeID: Int64 = 0
    /// The shared tab's browser (tab), else 0.
    var tabBrowser: Int32 = 0
    var audio = false

    static let cancel = ChromiumHostDesktopMediaAnswer(sourceType: [])
}

/// The cmux dialogs of the device choosers and the screen-share picker (``ChromiumHostChoosers``):
/// plain data from the host's state and the person's answer read back.
enum ChromiumHostChooserDialogs {
    static let deviceIdentifier = "browser.chromiumHost.deviceChooser"
    static let shareIdentifier = "browser.chromiumHost.screenShare"
    static let deviceField = "device"
    static let sourceField = "source"
    static let audioField = "audio"

    // MARK: Devices

    /// The chooser's dialog: Chromium's title and labels where it sent them (localized in its locale,
    /// which is cmux's), its rows as one choice (a check per row when several may be chosen), and
    /// Cancel, Scan Again (Bluetooth) and Connect. Connect is there only when it can answer: with a
    /// row, or for the Bluetooth scanning prompt. No row is chosen until the person chooses one, as
    /// Chrome's DeviceChooserContentView opens with no table selection; `selected` (the values of the
    /// dialog that showed `shown`) keeps each chosen device chosen at its new row.
    static func deviceSpec(_ state: ChromiumHostDeviceChooserState, selected: [String: CmuxDialogValue],
                           shown: ChromiumHostDeviceChooserState?) -> CmuxDialogSpec {
        let origin = state.origin
        let title = state.title.isEmpty ? String(format: Strings.deviceTitle, origin) : state.title
        var lines: [String] = []
        if !state.adapterEnabled {
            lines.append(Strings.bluetoothOff)
        } else if !state.adapterAuthorized {
            lines.append(Strings.bluetoothDenied)
        } else if !state.initialized || state.refreshing {
            lines.append(Strings.searching)
        } else if state.options.isEmpty {
            lines.append(state.noOptionsText.isEmpty ? Strings.noDevices : state.noOptionsText)
        }
        let chosen = Set(keptRows(selected, shown: shown, in: state))
        var fields: [CmuxDialogField] = []
        if state.allowsMultiple {
            fields = state.options.indices.map { index in
                CmuxDialogField.check(id: "\(deviceField).\(index)", title: state.options[index].name, on: chosen.contains(index))
            }
        } else if !state.options.isEmpty {
            // The first entry stands for no choice: a Connect on it answers no row.
            let options = [CmuxDialogOption(label: Strings.chooseDevice, value: "")]
                + state.options.indices.map { CmuxDialogOption(label: state.options[$0].name, value: String($0)) }
            fields = [.choice(id: deviceField, label: nil, options: options, selected: chosen.min().map { String($0) } ?? "")]
        }
        var buttons = [CmuxDialogButton.cancel()]
        if state.offersRescan { buttons.append(CmuxDialogButton(id: "rescan", title: Strings.rescan)) }
        if !state.options.isEmpty || state.bothButtonsAlwaysEnabled {
            buttons.append(CmuxDialogButton(id: "connect", title: state.okLabel.isEmpty ? Strings.connect : state.okLabel, role: .default))
        }
        return CmuxDialogSpec(title: title, lines: lines, origin: origin.isEmpty ? nil : origin, fields: fields,
                              buttons: buttons, identifier: deviceIdentifier)
    }

    /// The rows of `state` that hold the devices chosen in the dialog that showed `shown`. A row follows
    /// its device when rows above it go, as Chrome's chooser table moves its selection on
    /// `OnOptionRemoved` (chrome/browser/ui/views/device_chooser_content_view.cc). Chromium sends whole
    /// states, so a device is known by its name, which Chromium's chooser controllers keep unique (a
    /// repeated name gets the device's id added); a device that went, or a name on more than one row,
    /// is chosen nowhere.
    static func keptRows(_ selected: [String: CmuxDialogValue], shown: ChromiumHostDeviceChooserState?,
                         in state: ChromiumHostDeviceChooserState) -> [Int] {
        guard let shown else { return [] }
        let prefix = "\(deviceField)."
        var rows = selected.compactMap { key, value in
            key.hasPrefix(prefix) && value.bool == true ? Int(key.dropFirst(prefix.count)) : nil
        }
        if let row = selected[deviceField]?.text.flatMap(Int.init) { rows.append(row) }
        func unique(_ name: String, in options: [ChromiumHostDeviceChooserState.Option]) -> Int? {
            let matches = options.indices.filter { options[$0].name == name }
            return matches.count == 1 ? matches[0] : nil
        }
        return rows.filter { shown.options.indices.contains($0) }.compactMap { row in
            let name = shown.options[row].name
            return unique(name, in: shown.options) == nil ? nil : unique(name, in: state.options)
        }.sorted()
    }

    /// The person's answer: Connect selects the chosen rows; a dismissal (its tab or window went) closes
    /// the chooser, as Chrome's bubble does when it loses its anchor.
    static func deviceAnswer(_ answer: CmuxDialogAnswer, state: ChromiumHostDeviceChooserState) -> ChromiumHostDeviceAnswer {
        if answer.isDismissal { return .init(action: .close) }
        switch answer.button {
        case "rescan": return .init(action: .rescan)
        case "connect":
            let rows: [Int] = if state.allowsMultiple {
                state.options.indices.filter { answer.isOn("\(deviceField).\($0)") }
            } else {
                answer.text(deviceField).flatMap(Int.init).map { [$0] } ?? []
            }
            let valid = rows.filter { state.options.indices.contains($0) }
            // A Connect with nothing chosen is a cancel, except the scanning prompt's Allow, which has no rows.
            guard !valid.isEmpty || state.bothButtonsAlwaysEnabled else { return .init(action: .cancel) }
            return .init(action: .select, rows: valid)
        default: return .init(action: .cancel)
        }
    }

    // MARK: Screen share

    /// The picker: one choice of the sources the request allows (screens and windows from
    /// ScreenCaptureKit, this tab, cmux's other Chromium tabs), the page's preferred kind first, and
    /// Share audio when the page asked for it.
    static func shareSpec(_ request: ChromiumHostDesktopMediaRequest, sources: ChromiumHostShareSources,
                          tabs: [ChromiumHostShareTab]) -> CmuxDialogSpec {
        var groups: [(ChromiumHostDesktopMediaRequest.Sources, [CmuxDialogOption])] = []
        if request.sources.contains(.screen) {
            groups.append((.screen, sources.screens.map { CmuxDialogOption(label: String(format: Strings.screen, $0.name), value: "screen:\($0.id)") }))
        }
        if request.sources.contains(.window) {
            groups.append((.window, sources.windows.map { window in
                CmuxDialogOption(label: String(format: Strings.window, window.title, window.app), value: "window:\(window.id)")
            }))
        }
        if request.sources.contains(.currentTab) {
            groups.append((.currentTab, [CmuxDialogOption(label: Strings.thisTab, value: "current")]))
        }
        if request.sources.contains(.tab) {
            groups.append((.tab, tabs.map { CmuxDialogOption(label: String(format: Strings.tab, $0.title), value: "tab:\($0.browser)") }))
        }
        // The page's displaySurface first, as Chrome opens its picker on that pane.
        let ordered = groups.filter { request.preferred.contains($0.0) } + groups.filter { !request.preferred.contains($0.0) }
        let options = ordered.flatMap(\.1)
        var lines: [String] = []
        if !sources.listed, request.sources.contains(.screen) || request.sources.contains(.window) {
            lines.append(Strings.recordingPermission)
        }
        var fields: [CmuxDialogField] = []
        if !options.isEmpty { fields.append(.choice(id: sourceField, label: nil, options: options, selected: options.first?.value)) }
        if request.requestsAudio { fields.append(.check(id: audioField, title: Strings.audio, on: true)) }
        var buttons = [CmuxDialogButton.cancel()]
        if !options.isEmpty { buttons.append(CmuxDialogButton(id: "share", title: Strings.share, role: .default)) }
        let name = request.appName
        return CmuxDialogSpec(title: String(format: Strings.shareTitle, name), lines: lines, origin: name.isEmpty ? nil : name,
                              fields: fields, buttons: buttons, identifier: shareIdentifier)
    }

    /// The person's answer: the chosen source, or a cancel for anything else.
    static func shareAnswer(_ answer: CmuxDialogAnswer, request: ChromiumHostDesktopMediaRequest) -> ChromiumHostDesktopMediaAnswer {
        guard !answer.isDismissal, answer.button == "share", let value = answer.text(sourceField) else { return .cancel }
        let audio = request.requestsAudio && answer.isOn(audioField)
        let kind = value.prefix { $0 != ":" }
        let id = value.dropFirst(kind.count + 1)
        let picked: ChromiumHostDesktopMediaAnswer? = switch kind {
        case "screen": UInt32(id).map { ChromiumHostDesktopMediaAnswer(sourceType: .screen, nativeID: Int64($0), audio: audio) }
        case "window": UInt32(id).map { ChromiumHostDesktopMediaAnswer(sourceType: .window, nativeID: Int64($0), audio: audio) }
        case "tab": Int32(id).map { ChromiumHostDesktopMediaAnswer(sourceType: .tab, tabBrowser: $0, audio: audio) }
        case "current": ChromiumHostDesktopMediaAnswer(sourceType: .currentTab, audio: audio)
        default: nil
        }
        guard let picked, request.sources.contains(picked.sourceType) else { return .cancel }
        return picked
    }

    // MARK: Strings

    enum Strings {
        static let deviceTitle = String(localized: "browser.chromiumHost.device.title", defaultValue: "%@ wants to connect to a device", bundle: .module)
        static let chooseDevice = String(localized: "browser.chromiumHost.device.choose", defaultValue: "Choose a device", bundle: .module)
        static let connect = String(localized: "browser.chromiumHost.device.connect", defaultValue: "Connect", bundle: .module)
        static let rescan = String(localized: "browser.chromiumHost.device.rescan", defaultValue: "Scan Again", bundle: .module)
        static let searching = String(localized: "browser.chromiumHost.device.searching", defaultValue: "Searching for devices…", bundle: .module)
        static let noDevices = String(localized: "browser.chromiumHost.device.none", defaultValue: "No compatible devices found.", bundle: .module)
        static let bluetoothOff = String(localized: "browser.chromiumHost.device.bluetoothOff", defaultValue: "Bluetooth is turned off.", bundle: .module)
        static let bluetoothDenied = String(localized: "browser.chromiumHost.device.bluetoothDenied",
                                            defaultValue: "cmux is not allowed to use Bluetooth. Allow it in System Settings.", bundle: .module)
        static let shareTitle = String(localized: "browser.chromiumHost.share.title", defaultValue: "Choose what to share with %@", bundle: .module)
        static let share = String(localized: "browser.chromiumHost.share.share", defaultValue: "Share", bundle: .module)
        static let screen = String(localized: "browser.chromiumHost.share.screen", defaultValue: "Entire screen: %@", bundle: .module)
        static let window = String(localized: "browser.chromiumHost.share.window", defaultValue: "Window: %1$@ (%2$@)", bundle: .module)
        static let tab = String(localized: "browser.chromiumHost.share.tab", defaultValue: "Tab: %@", bundle: .module)
        static let thisTab = String(localized: "browser.chromiumHost.share.thisTab", defaultValue: "This tab", bundle: .module)
        static let audio = String(localized: "browser.chromiumHost.share.audio", defaultValue: "Also share audio", bundle: .module)
        static let recordingPermission = String(
            localized: "browser.chromiumHost.share.permission",
            defaultValue: "To share a screen or window, allow cmux in System Settings > Privacy & Security > Screen & System Audio Recording.",
            bundle: .module)
    }
}
