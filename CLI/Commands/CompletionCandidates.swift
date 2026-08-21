import ArgumentParser
import Foundation

/// Candidate providers for dynamic shell completion.
///
/// Every handler runs on the user's Tab key, so it must remain bounded, quiet,
/// and successful even when the cmux app is unavailable. A broken or absent app
/// degrades to no suggestions instead of a hung or noisy shell.
enum CompletionCandidates {
    /// Upper bound on a completion round trip. Past this the shell gets nothing.
    private static let timeout: TimeInterval = 0.5

    static func workspaces(_ arguments: [String]) -> [String] {
        fetch(method: "workspace.list") { $0["ref"] as? String }
    }

    static func surfaces(_ arguments: [String]) -> [String] {
        fetch(method: "surface.list") { $0["ref"] as? String }
    }

    static func windows(_ arguments: [String]) -> [String] {
        fetch(method: "window.list") { $0["ref"] as? String }
    }

    static func panes(_ arguments: [String]) -> [String] {
        fetch(method: "pane.list") { $0["ref"] as? String }
    }

    static func panels(_ arguments: [String]) -> [String] {
        fetch(method: "surface.list") { $0["ref"] as? String }
    }

    static func tabs(_ arguments: [String]) -> [String] {
        fetch(method: "browser.tab.list") { $0["ref"] as? String }
    }

    static func themes(_ arguments: [String]) -> [String] {
        CMUXCLI(args: CommandLine.arguments).availableThemeNames()
    }

    static func vms(_ arguments: [String]) -> [String] {
        fetch(method: "vm.list") { $0["id"] as? String }
    }

    /// Returns candidates, or an empty array for every failure mode.
    private static func fetch(
        method: String,
        mapping: ([String: Any]) -> String?
    ) -> [String] {
        do {
            let deadline = Date.now.addingTimeInterval(timeout)
            let processEnvironment = ProcessInfo.processInfo.environment
            let environmentSocketPath = try CLISocketEnvironment.socketPath(in: processEnvironment)
            let bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
            let requestedSocketPath = environmentSocketPath ?? CLISocketPathResolver.defaultSocketPath(
                bundleIdentifier: bundleIdentifier,
                environment: processEnvironment
            )
            let source: CLISocketPathSource = environmentSocketPath == nil ? .implicitDefault : .environment
            let resolution = CLISocketPathResolver(
                environment: processEnvironment,
                bundleIdentifier: bundleIdentifier
            ).resolve(requestedPath: requestedSocketPath, source: source)
            guard resolution.hasLiveSocket else { return [] }

            let socketPath = resolution.selectedPath ?? requestedSocketPath
            let client = SocketClient(path: socketPath)
            defer { client.close() }

            try client.connect(deadline: deadline)
            guard let authenticationTimeout = remainingTimeout(until: deadline) else { return [] }
            try CMUXCLI.authenticateSocketClientIfNeeded(
                client,
                explicitPassword: nil,
                socketPath: socketPath,
                responseTimeout: authenticationTimeout,
                deadline: deadline
            )
            guard let responseTimeout = remainingTimeout(until: deadline) else { return [] }
            let payload = try client.sendV2(method: method, responseTimeout: responseTimeout)
            guard let listName = method.split(separator: ".").dropLast().last.map({ "\($0)s" }),
                  let items = payload[listName] as? [[String: Any]] else {
                return []
            }
            return items.compactMap(mapping)
        } catch {
            return []
        }
    }

    private static func remainingTimeout(until deadline: Date) -> TimeInterval? {
        let remaining = deadline.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }
}

/// Hidden entry point that lets tests and shell scripts exercise handlers directly.
struct CompleteCandidates: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete-candidates",
        shouldDisplay: false
    )

    @Argument var kind: String

    func run() throws {
        let candidates: [String]
        switch kind {
        case "workspaces": candidates = CompletionCandidates.workspaces([])
        case "surfaces": candidates = CompletionCandidates.surfaces([])
        case "windows": candidates = CompletionCandidates.windows([])
        case "panes": candidates = CompletionCandidates.panes([])
        case "panels": candidates = CompletionCandidates.panels([])
        case "tabs": candidates = CompletionCandidates.tabs([])
        case "themes": candidates = CompletionCandidates.themes([])
        case "vms": candidates = CompletionCandidates.vms([])
        default: candidates = []
        }

        for candidate in candidates {
            print(candidate)
        }
    }
}
