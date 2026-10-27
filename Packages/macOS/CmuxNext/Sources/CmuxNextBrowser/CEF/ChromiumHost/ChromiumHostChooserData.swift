import Foundation

// The requests of the fork's color chooser, device chooser and screen-share picker handlers (fork
// API 31, task 227 of plans/cmux-next/chrome-parity/p01-process.md) as Swift values, read from the
// fork's structs (include/cef_cmux.h) during the handler's call. The byte offsets are the LP64
// layout ChromiumHost/src/host_choosers.h pins with static_asserts (its Fork* copies, which the host
// and the remote shim read and rebuild); every macOS cmux runs is LP64.

/// `<input type=color>`'s chooser (`cmux_color_chooser_t`). Colors are 0xAARRGGBB.
nonisolated struct ChromiumHostColorChooserRequest: Equatable, Sendable {
    nonisolated struct Suggestion: Equatable, Sendable {
        var color: UInt32
        /// The `<datalist>` option's label, empty for none.
        var label: String
    }

    var token: Int64
    var color: UInt32
    var suggestions: [Suggestion]
}

/// A Web Bluetooth, WebUSB, WebHID or Web Serial chooser's whole state (`cmux_device_chooser_t`), sent
/// again at every change, as Chrome's `ChooserController::View` hears of each.
nonisolated struct ChromiumHostDeviceChooserState: Equatable, Sendable {
    nonisolated struct Option: Equatable, Sendable {
        var name: String
        /// Bluetooth signal strength 0-4, -1 when not shown.
        var signalStrength: Int32
        var connected: Bool
        var paired: Bool
    }

    var token: Int64
    /// The requesting origin ("https://example.com").
    var origin: String
    /// Chromium's localized texts: the title, the text with no rows, the OK button.
    var title: String
    var noOptionsText: String
    var okLabel: String
    var showsSignalStrength: Bool
    var offersRescan: Bool
    var allowsMultiple: Bool
    /// The first scan finished.
    var initialized: Bool
    var refreshing: Bool
    var adapterEnabled: Bool
    var adapterAuthorized: Bool
    /// The Bluetooth scanning prompt: Allow works with no row selected.
    var bothButtonsAlwaysEnabled: Bool
    var options: [Option]
}

/// The screen-share picker of getDisplayMedia() and chrome.desktopCapture (`cmux_desktop_media_request_t`).
nonisolated struct ChromiumHostDesktopMediaRequest: Equatable, Sendable {
    /// `CMUX_DESKTOP_MEDIA_*`.
    nonisolated struct Sources: OptionSet, Hashable, Sendable {
        let rawValue: Int32
        static let screen = Sources(rawValue: 1 << 0)
        static let window = Sources(rawValue: 1 << 1)
        static let tab = Sources(rawValue: 1 << 2)
        static let currentTab = Sources(rawValue: 1 << 3)
    }

    var token: Int64
    /// The requesting origin or extension name.
    var appName: String
    var sources: Sources
    /// The page's displaySurface preference, empty for none.
    var preferred: Sources
    var requestsAudio: Bool
}

// The fork structs' sizes in this layout (the leading `size` field of an older struct is smaller).
private nonisolated let colorChooserSize: Int32 = 48
private nonisolated let deviceOptionStride = 24
private nonisolated let deviceChooserSize: Int32 = 96
private nonisolated let desktopMediaSize: Int32 = 40

nonisolated extension ChromiumHostColorChooserRequest {
    /// The fork's struct at `address`, read during the handler's call; nil for NULL or an older struct.
    init?(forkAddress address: UInt) {
        guard let base = forkStruct(at: address, size: colorChooserSize) else { return nil }
        // SAFETY: `base` is the fork's cmux_color_chooser_t, valid during the handler's call (the caller's
        // contract), at least colorChooserSize bytes; offsets are host_choosers.h's ForkColorChooser.
        let count = Int(max(0, unsafe base.load(fromByteOffset: 40, as: Int32.self)))
        let colors = unsafe base.load(fromByteOffset: 24, as: UnsafePointer<UInt32>?.self)
        let labels = unsafe base.load(fromByteOffset: 32, as: UnsafePointer<UnsafePointer<CChar>?>?.self)
        var suggestions: [Suggestion] = []
        if let colors = unsafe colors {
            suggestions.reserveCapacity(count)
            for index in 0..<count {
                // SAFETY: the fork's arrays hold suggestion_count entries for the call.
                let label = unsafe labels.map { unsafe forkText($0[index]) } ?? ""
                unsafe suggestions.append(Suggestion(color: colors[index], label: label))
            }
        }
        unsafe self.init(token: base.load(fromByteOffset: 8, as: Int64.self),
                         color: base.load(fromByteOffset: 16, as: UInt32.self), suggestions: suggestions)
    }
}

nonisolated extension ChromiumHostDeviceChooserState {
    /// The fork's struct at `address`, read during the handler's call; nil for NULL or an older struct.
    init?(forkAddress address: UInt) {
        guard let base = forkStruct(at: address, size: deviceChooserSize) else { return nil }
        // SAFETY: `base` is the fork's cmux_device_chooser_t, valid during the handler's call, at least
        // deviceChooserSize bytes; offsets are host_choosers.h's ForkDeviceChooser and ForkDeviceOption.
        func flag(_ offset: Int) -> Bool { unsafe base.load(fromByteOffset: offset, as: Int32.self) != 0 }
        func string(_ offset: Int) -> String { unsafe forkText(base.load(fromByteOffset: offset, as: UnsafePointer<CChar>?.self)) }
        let count = Int(max(0, unsafe base.load(fromByteOffset: 88, as: Int32.self)))
        var options: [Option] = []
        if let rows = unsafe base.load(fromByteOffset: 80, as: UnsafeRawPointer?.self) {
            options.reserveCapacity(count)
            for index in 0..<count {
                // SAFETY: option_count rows of deviceOptionStride bytes each, valid for the call.
                let row = unsafe rows.advanced(by: index * deviceOptionStride)
                unsafe options.append(Option(name: forkText(row.load(as: UnsafePointer<CChar>?.self)),
                                             signalStrength: row.load(fromByteOffset: 8, as: Int32.self),
                                             connected: row.load(fromByteOffset: 12, as: Int32.self) != 0,
                                             paired: row.load(fromByteOffset: 16, as: Int32.self) != 0))
            }
        }
        unsafe self.init(token: base.load(fromByteOffset: 8, as: Int64.self), origin: string(16), title: string(24),
                         noOptionsText: string(32), okLabel: string(40), showsSignalStrength: flag(48),
                         offersRescan: flag(52), allowsMultiple: flag(56), initialized: flag(60), refreshing: flag(64),
                         adapterEnabled: flag(68), adapterAuthorized: flag(72), bothButtonsAlwaysEnabled: flag(76),
                         options: options)
    }
}

nonisolated extension ChromiumHostDesktopMediaRequest {
    /// The fork's struct at `address`, read during the handler's call; nil for NULL or an older struct.
    init?(forkAddress address: UInt) {
        guard let base = forkStruct(at: address, size: desktopMediaSize) else { return nil }
        // SAFETY: `base` is the fork's cmux_desktop_media_request_t, valid during the handler's call, at
        // least desktopMediaSize bytes; offsets are host_choosers.h's ForkDesktopMediaRequest.
        unsafe self.init(token: base.load(fromByteOffset: 8, as: Int64.self),
                         appName: forkText(base.load(fromByteOffset: 16, as: UnsafePointer<CChar>?.self)),
                         sources: Sources(rawValue: base.load(fromByteOffset: 24, as: Int32.self)),
                         preferred: Sources(rawValue: base.load(fromByteOffset: 28, as: Int32.self)),
                         requestsAudio: base.load(fromByteOffset: 32, as: Int32.self) != 0)
    }
}

/// The struct at `address` when its leading `size` field is at least `size`.
private nonisolated func forkStruct(at address: UInt, size: Int32) -> UnsafeRawPointer? {
    // SAFETY: a nonzero address is the fork's struct for the handler's call; its first field is its size.
    guard let base = unsafe UnsafeRawPointer(bitPattern: address), unsafe base.load(as: Int32.self) >= size else { return nil }
    return unsafe base
}

/// A C string of a fork struct, "" for NULL; invalid UTF-8 is repaired.
private nonisolated func forkText(_ pointer: UnsafePointer<CChar>?) -> String {
    // SAFETY: the fork's strings are NUL-terminated and valid during the handler's call.
    guard let pointer = unsafe pointer else { return "" }
    return unsafe String(cString: pointer)
}
