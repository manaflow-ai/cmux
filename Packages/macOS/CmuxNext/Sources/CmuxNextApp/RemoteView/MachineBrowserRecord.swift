import CmuxNextBrowserTabs
import Foundation

/// Where a new browser tab of a pane runs (cx-2cob design, decided
/// 2026-10-09): this Mac for this Mac's panes; the pane's machine for
/// another machine's panes while that machine's browser host is available
/// (a cached check, never a wait on the key press). Otherwise this Mac's
/// tab, which says so with the This Mac omnibar chip; the chip's menu
/// offers Open on <machine>.
nonisolated enum BrowserPlacement: Equatable, Sendable {
    case local
    case machine(String)

    static func resolve(isLocal: Bool, machine: String, hostAvailable: Bool) -> BrowserPlacement {
        isLocal || !hostAvailable ? .local : .machine(machine)
    }

    /// The address a new tab opens: on a machine, its record with `url` as
    /// the first page. A local file or a Chromium internal page is this
    /// Mac's own and stays as it is.
    func address(for url: URL?) -> URL? {
        guard case let .machine(machine) = self else { return url }
        if let url, !["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return MachineBrowserRecord(machine: machine, initialURL: url).url
    }
}

/// Why a machine browser tab shows no page yet (the design's not-ready
/// states, cx-2cob slice 2).
nonisolated enum MachineBrowserState: Equatable, Sendable {
    case ready
    /// The machine has no browser installed.
    case notInstalled(String)
    /// The machine's platform has no browser host yet (Cloud machines run Linux).
    case unavailable(String)
    case notConnected(String)
    /// The machine's cmux-tui has no browser runtimes (update it).
    case tooOld(String)
    case starting(String)
    /// The browser stopped or did not start; the reason ends with its log.
    case failed(String, String)

    /// `installed`: the machine's last status (nil: not known yet).
    static func resolve(name: String, isCloud: Bool, connected: Bool, installed: Bool?) -> MachineBrowserState {
        guard connected else { return .notConnected(name) }
        if installed == true { return .ready }
        return isCloud ? .unavailable(name) : .notInstalled(name)
    }

    var message: String {
        switch self {
        case .ready: ""
        case let .notInstalled(name): MachineBrowserStrings.notInstalled(name)
        case let .unavailable(name): MachineBrowserStrings.unavailable(name)
        case let .notConnected(name): MachineBrowserStrings.notConnected(name)
        case let .tooOld(name): MachineBrowserStrings.tooOld(name)
        case let .starting(name): MachineBrowserStrings.starting(name)
        case let .failed(name, reason): MachineBrowserStrings.failed(name, reason)
        }
    }
}
