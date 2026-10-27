import AppKit
import CmuxNextCompat
import ScreenCaptureKit

/// One of cmux's Chromium tabs a page may share (`CMUX_DESKTOP_MEDIA_TAB`).
nonisolated struct ChromiumHostShareTab: Equatable, Sendable {
    var browser: Int32
    var title: String
}

/// The screens and windows a page may share, as ScreenCaptureKit lists them for cmux, which asks for
/// the Screen Recording permission the first time, as Chrome's picker does through its
/// ScreenCaptureKit source lists (chrome/browser/media/webrtc/desktop_media_list*.cc).
nonisolated struct ChromiumHostShareSources: Equatable, Sendable {
    nonisolated struct Screen: Equatable, Sendable {
        /// The CGDirectDisplayID.
        var id: UInt32
        var name: String
    }

    nonisolated struct Window: Equatable, Sendable {
        /// The CGWindowID.
        var id: UInt32
        var title: String
        var app: String
    }

    var screens: [Screen]
    var windows: [Window]
    /// ScreenCaptureKit answered: false when cmux may not record the screen (no permission).
    var listed: Bool

    static let none = ChromiumHostShareSources(screens: [], windows: [], listed: false)

    /// Lists them and calls `then` on the main actor. ScreenCaptureKit answers on its own queue; the
    /// values are copied there and the main actor only names the screens.
    static func list(then: @escaping @MainActor (ChromiumHostShareSources) -> Void) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            let sources = content.map { Self(content: $0, excludingPID: ownPID) } ?? .none
            MainRunLoopBlock.perform { then(sources.namingScreens()) }
        }
    }

    /// The displays, and the titled normal-level windows of other apps (cmux's own windows are where the
    /// page is: a tab shares through TAB, as Chrome leaves its own windows out of the window list).
    private init(content: SCShareableContent, excludingPID pid: pid_t) {
        screens = content.displays.map { Screen(id: $0.displayID, name: "") }
        windows = content.windows.compactMap { window in
            guard window.windowLayer == 0, window.isOnScreen, let title = window.title, !title.isEmpty,
                  let app = window.owningApplication, app.processID != pid else { return nil }
            return Window(id: window.windowID, title: title, app: app.applicationName)
        }
        listed = true
    }

    init(screens: [Screen], windows: [Window], listed: Bool) {
        self.screens = screens
        self.windows = windows
        self.listed = listed
    }

    /// The screens with their names (NSScreen's, main actor); the display id when no screen has it.
    @MainActor func namingScreens() -> ChromiumHostShareSources {
        var named = self
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let names = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[key] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
        }, uniquingKeysWith: { first, _ in first })
        named.screens = screens.map { Screen(id: $0.id, name: names[$0.id] ?? String($0.id)) }
        return named
    }
}
