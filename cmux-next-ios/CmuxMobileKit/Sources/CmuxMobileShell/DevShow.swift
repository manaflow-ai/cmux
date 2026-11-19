#if DEBUG && os(iOS)
import CmuxMobileModel
import CmuxMobileSettings
import Foundation
import OSLog
import SwiftUI

private let devShowLog = Logger(subsystem: "dev.cmux.mobile", category: "dev-show")

/// DEBUG only (compiled out of Release, Production and the shipping configurations): the hook
/// the iOS dev CLI (`cmux-next-ios/scripts/cmux-ios`) drives the app with.
///
/// Two ways in, both answered by one receipt:
///
/// - A launch: the CLI starts the app with a target's DEBUG launch arguments and environment
///   (mock data, a demo driver, a Settings page) plus `CMUX_DEV_SHOW_NONCE` and
///   `CMUX_DEV_SHOW_TARGET`. Once the root destination (Welcome, setup or the shell) has drawn,
///   the app writes the receipt.
/// - A link, with the app already running (mock or the person's own signed-in data):
///   `cmux-next://dev/show?target=T&nonce=N[&tab=home|workspaces|feed|settings]
///   [&settings=<SettingsRoute case>][&appearance=light|dark|system][&sidebar=open|closed]`,
///   opened by `simctl openurl` or `devicectl … --payload-url`. The shell applies it in process
///   (no relaunch, nothing reloaded) and writes the receipt on the next frame.
///
/// The receipt (`relativePath` in the app's data container) names the launch or link nonce and
/// what is on screen: the destination, the tab, the Settings path, whether the team sidebar is
/// open and the appearance. The CLI deletes the old receipt, waits for the one with its nonce,
/// checks it against the target and only then takes the screenshot, so a screenshot never shows
/// the screen before the one asked for. It holds nothing private: no account, Mac or token.
@MainActor
@Observable
final class DevShow {
    static let shared = DevShow()
    nonisolated static let relativePath = "Library/Application Support/cmux-dev-show/shown.json"

    /// One in-process request from a `cmux-next://dev/show` link.
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

    /// The link waiting for the shell (set by RootView, applied by `DevShowObserver`).
    var request: Request?

    /// The launch's request from the CLI, if any (`CMUX_DEV_SHOW_NONCE`, `CMUX_DEV_SHOW_TARGET`).
    @ObservationIgnored private let launch: (nonce: String, target: String)?
    @ObservationIgnored private var launchWritten = false

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
        let settings_path: [String]
        let sidebar_open: Bool
        let appearance: String
        let demo: String?
        let bundle_id: String
        let written_at: String
    }

    /// The root drew `destination` after launch: the launch receipt, once.
    func launchShown(destination: String, shell: ShellModel?, appearance: AppearanceMode, demo: String?) {
        guard let launch, !launchWritten else { return }
        launchWritten = true
        write(nonce: launch.nonce, target: launch.target, source: "launch", destination: destination,
              shell: shell, appearance: appearance, demo: demo)
    }

    /// A link that arrives while the root shows Welcome or setup: nothing to navigate, so the
    /// receipt says where the app is and the CLI reports the miss.
    func linkShown(_ request: Request, destination: String, appearance: AppearanceMode) {
        write(nonce: request.nonce, target: request.target, source: "link", destination: destination,
              shell: nil, appearance: appearance, demo: nil)
    }

    /// Applies a link to the shell; the receipt follows on the next frame (`DevShowObserver`).
    func apply(_ request: Request, to shell: ShellModel) {
        if let mode = request.appearance { shell.settings.appearance = mode }
        if let open = request.sidebar { open ? shell.sidebar.open() : shell.sidebar.close() }
        if let route = request.settings {
            shell.tab = .settings
            shell.settingsPath = [route]
        } else if let tab = request.tab {
            shell.tab = tab
            if tab == .settings { shell.settingsPath = [] }
        }
    }

    func write(nonce: String, target: String, source: String, destination: String, shell: ShellModel?,
               appearance: AppearanceMode, demo: String?) {
        let body = Shown(
            nonce: nonce, target: target, source: source, destination: destination,
            tab: shell?.tab.rawValue,
            settings_path: shell?.settingsPath.map { "\($0)" } ?? [],
            sidebar_open: shell?.sidebar.isOpen ?? false,
            appearance: appearance.rawValue,
            demo: demo,
            bundle_id: Bundle.main.bundleIdentifier ?? "",
            written_at: ISO8601DateFormatter().string(from: Date())
        )
        let receipt = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(Self.relativePath)
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
}

/// The shell's side of `DevShow`: the launch receipt once the shell has drawn, and each link
/// applied in process with its receipt one frame later. Its own modifier, so ShellView's chain
/// stays small enough to type-check.
struct DevShowObserver: ViewModifier {
    let shell: ShellModel
    let demo: String?

    func body(content: Content) -> some View {
        content
            .task {
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
                                         shell: shell, appearance: shell.settings.appearance, demo: nil)
                }
            }
    }
}
#endif
