#if DEBUG && os(iOS)
import CmuxMobileModel
import CmuxMobileSettings
import Foundation
import OSLog
import SwiftUI
import UIKit

private let devShowLog = Logger(subsystem: "dev.cmux.mobile", category: "dev-show")

/// DEBUG only (compiled out of Release, Production and the shipping configurations): the hook
/// the iOS dev CLI (`cmux-next-ios/scripts/cmux-ios`) drives the app with.
///
/// Two ways in, both answered by one receipt:
///
/// - A launch: the CLI starts the app with a target's DEBUG launch arguments and environment
///   (mock data, a demo driver, a Settings page) plus `CMUX_DEV_SHOW_NONCE` and
///   `CMUX_DEV_SHOW_TARGET`. Once the root destination (Welcome, setup or the shell) is up, the
///   app writes the receipt; a launch with a demo driver writes it again (`demo_done`) once the
///   driver's `run` has returned, which for the CLI's catalog demos means its state is set.
/// - A request, with the app already running (mock or the person's own signed-in data):
///   `cmux-next://dev/show?target=T&nonce=N[&tab=home|workspaces|feed|settings]
///   [&settings=<SettingsRoute case>][&appearance=light|dark|system][&sidebar=open|closed]`.
///   On a phone it comes as the link (`devicectl … process launch --payload-url`, which hands
///   it to this bundle only). On a simulator the CLI writes it to `requestPath` in this app's
///   container and posts the Darwin notification `<bundle id>.dev-show`: `simctl openurl` would
///   ask "Open in …?" and could reach another tagged build that claims the same scheme. The
///   shell applies it in process (no relaunch, nothing reloaded): the tab with its pushed pages
///   cleared, a Settings page, the team sidebar, and a look that is not saved (the window's
///   override only, the person's Appearance setting stays). It writes the receipt after the
///   update.
///
/// The receipt (`relativePath` in the app's data container) names the nonce and what is on
/// screen: the destination, the tab and how many pages are pushed on it, the Settings path,
/// whether the team sidebar is open, the look, and the demo. The CLI deletes the old receipt,
/// waits for the one with its nonce, checks it against the target and then takes the
/// screenshot. A demo driver or an animation still needs the CLI's per-target settle (pacing,
/// not synchronization). The receipt holds nothing private: no account, Mac or token.
@MainActor
@Observable
final class DevShow {
    static let shared = DevShow()
    nonisolated static let relativePath = "Library/Application Support/cmux-dev-show/shown.json"
    nonisolated static let requestPath = "Library/Application Support/cmux-dev-show/request.txt"

    /// One in-process request (a `cmux-next://dev/show` link).
    struct Request: Equatable {
        var nonce: String
        var target: String
        var tab: RootTab?
        var settings: SettingsRoute?
        var appearance: AppearanceMode?
        var sidebar: Bool?

        /// Nil for any URL that is not a well-formed dev show link (the app then opens it as usual).
        init?(url: URL) {
            guard url.scheme == "cmux-next", url.host == "dev", url.path == "/show",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            guard let nonce = value("nonce"), Self.isToken(nonce), let target = value("target"), Self.isToken(target) else { return nil }
            self.nonce = nonce
            self.target = target
            if let raw = value("tab") {
                guard let tab = RootTab(rawValue: raw) else { return nil }
                self.tab = tab
            }
            if let raw = value("settings") {
                guard let route = SettingsRoute(name: raw) else { return nil }
                settings = route
            }
            if let raw = value("appearance") {
                guard let mode = AppearanceMode(rawValue: raw) else { return nil }
                appearance = mode
            }
            if let raw = value("sidebar") {
                guard raw == "open" || raw == "closed" else { return nil }
                sidebar = raw == "open"
            }
        }

        /// Ids the CLI makes: letters, digits, dot, dash and underscore, at most 96.
        static func isToken(_ text: String) -> Bool {
            !text.isEmpty && text.count <= 96 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// The request waiting for the shell (set by RootView or the simulator request watch,
    /// applied by `DevShowObserver`).
    var request: Request?

    /// The launch's request from the CLI, if any (`CMUX_DEV_SHOW_NONCE`, `CMUX_DEV_SHOW_TARGET`).
    @ObservationIgnored private let launch: (nonce: String, target: String)?
    @ObservationIgnored private var launchWritten = false
    @ObservationIgnored private var watching = false
    /// The look a request set for this process only (the window's override, not the setting).
    @ObservationIgnored private var lookOverride: AppearanceMode?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let nonce = environment["CMUX_DEV_SHOW_NONCE"], Request.isToken(nonce) {
            let target = environment["CMUX_DEV_SHOW_TARGET"].flatMap { Request.isToken($0) ? $0 : nil } ?? "launch"
            launch = (nonce, target)
        } else {
            launch = nil
        }
    }

    /// What the receipt says is on screen.
    struct Shown: Encodable, Equatable {
        var schema = 1
        let nonce: String
        let target: String
        /// `launch` or `link`.
        let source: String
        /// `welcome`, `setup` or `shell`.
        let destination: String
        let tab: String?
        /// Pages pushed on the shown tab (0: the tab's root).
        let path_depth: Int
        let settings_path: [String]
        let sidebar_open: Bool
        let appearance: String
        let demo: String?
        /// The launch's demo driver has returned from `run` (its state is set).
        let demo_done: Bool
        let bundle_id: String
        let written_at: String
    }

    /// The root drew `destination` after launch: the launch receipt, once.
    func launchShown(destination: String, shell: ShellModel?, appearance: AppearanceMode, demo: String?) {
        guard let launch, !launchWritten else { return }
        launchWritten = true
        write(nonce: launch.nonce, target: launch.target, source: "launch", destination: destination,
              shell: shell, appearance: appearance, demo: demo, demoDone: false)
    }

    /// The launch's demo driver returned: the launch receipt again, marked `demo_done`.
    func demoReached(_ demo: String, shell: ShellModel) {
        guard let launch else { return }
        write(nonce: launch.nonce, target: launch.target, source: "launch", destination: "shell",
              shell: shell, appearance: shell.settings.appearance, demo: demo, demoDone: true)
    }

    /// A request that arrives while the root shows Welcome or setup: nothing to navigate, so the
    /// receipt says where the app is and the CLI reports the miss.
    func linkShown(_ request: Request, destination: String, appearance: AppearanceMode) {
        write(nonce: request.nonce, target: request.target, source: "link", destination: destination,
              shell: nil, appearance: appearance, demo: nil, demoDone: false)
    }

    /// Applies a request to the shell; the receipt follows after the update (`DevShowObserver`).
    func apply(_ request: Request, to shell: ShellModel) {
        if let mode = request.appearance {
            // This process only: the window's override, never the saved Appearance setting.
            lookOverride = mode
            Self.overrideWindows(mode)
        }
        if let open = request.sidebar {
            if open { shell.sidebar.open() } else { shell.sidebar.close() }
        }
        if let route = request.settings {
            shell.tab = .settings
            shell.settingsPath = [route]
        } else if let tab = request.tab {
            shell.tab = tab
            // The tab's root, as the link names it: no page left pushed from before.
            switch tab {
            case .home: shell.homePath = NavigationPath()
            case .workspaces: shell.workspacesPath = []
            case .feed: shell.feedPath = []
            case .settings: shell.settingsPath = []
            }
        }
    }

    func write(nonce: String, target: String, source: String, destination: String, shell: ShellModel?,
               appearance: AppearanceMode, demo: String?, demoDone: Bool) {
        let depth: Int = switch shell?.tab {
        case .home: shell?.homePath.count ?? 0
        case .workspaces: shell?.workspacesPath.count ?? 0
        case .feed: shell?.feedPath.count ?? 0
        case .settings: shell?.settingsPath.count ?? 0
        case nil: 0
        }
        let body = Shown(
            nonce: nonce, target: target, source: source, destination: destination,
            tab: shell?.tab.rawValue,
            path_depth: depth,
            // The case name only: an associated value (a Mac id) never goes into the receipt.
            settings_path: shell?.settingsPath.map { String("\($0)".prefix(while: { $0 != "(" })) } ?? [],
            sidebar_open: shell?.sidebar.isOpen ?? false,
            appearance: (lookOverride ?? appearance).rawValue,
            demo: demo,
            demo_done: demoDone,
            bundle_id: Bundle.main.bundleIdentifier ?? "",
            written_at: ISO8601DateFormatter().string(from: Date())
        )
        let receipt = Self.containerURL(Self.relativePath)
        // Off the main actor: a small file, but file IO never runs on the main thread.
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(body)
                try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: receipt, options: .atomic)
                devShowLog.info("dev show receipt written: \(body.target, privacy: .public) \(body.source, privacy: .public)")
            } catch {
                devShowLog.error("dev show receipt not written: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Starts the simulator request watch: the Darwin notification `<bundle id>.dev-show`, posted
    /// by the CLI after it wrote `requestPath`, reads the request off the main thread.
    func startRequestWatch() {
        guard !watching, let bundle = Bundle.main.bundleIdentifier else { return }
        watching = true
        let callback: CFNotificationCallback = { _, _, _, _, _ in
            Task { @MainActor in DevShow.shared.readRequest() }
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, callback,
                                        "\(bundle).dev-show" as CFString, nil, .deliverImmediately)
    }

    private func readRequest() {
        let file = Self.containerURL(Self.requestPath)
        Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let request = Request(url: url) else {
                devShowLog.error("dev show request unreadable")
                return
            }
            try? FileManager.default.removeItem(at: file)
            await MainActor.run { DevShow.shared.request = request }
        }
    }

    nonisolated static func containerURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(path)
    }

    private static func overrideWindows(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = switch mode {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// The shell's side of `DevShow`: the launch receipt once the shell is up, and each request
/// applied in process with its receipt after the update. Its own modifier, so ShellView's
/// chain stays small enough to type-check.
struct DevShowObserver: ViewModifier {
    let shell: ShellModel
    let demo: String?

    func body(content: Content) -> some View {
        content
            .task {
                DevShow.shared.startRequestWatch()
                // The shell's state is set; the CLI's per-target settle covers its first frame and animations.
                await Task.yield()
                DevShow.shared.launchShown(destination: "shell", shell: shell, appearance: shell.settings.appearance, demo: demo)
            }
            .onChange(of: DevShow.shared.request, initial: true) { _, request in
                guard let request else { return }
                DevShow.shared.request = nil
                DevShow.shared.apply(request, to: shell)
                Task { @MainActor in
                    // After this update's transaction; the CLI's settle covers the push animation.
                    await Task.yield()
                    DevShow.shared.write(nonce: request.nonce, target: request.target, source: "link", destination: "shell",
                                         shell: shell, appearance: shell.settings.appearance, demo: nil, demoDone: false)
                }
            }
    }
}
#endif
