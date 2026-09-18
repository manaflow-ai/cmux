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
        fetch(method: "workspace.list", mapping: identifier)
    }

    static func surfaces(_ arguments: [String]) -> [String] {
        fetch(method: "surface.list", mapping: identifier)
    }

    static func windows(_ arguments: [String]) -> [String] {
        fetch(method: "window.list", mapping: identifier)
    }

    static func panes(_ arguments: [String]) -> [String] {
        fetch(method: "pane.list", mapping: identifier)
    }

    static func panels(_ arguments: [String]) -> [String] {
        fetch(method: "surface.list", mapping: identifier)
    }

    /// Browser tabs live in one workspace, so this is the one handler that has to
    /// say which. Without params the app answers for its *selected* workspace,
    /// which is not necessarily the one the completing shell sits in; the caller's
    /// own surface and workspace come from the environment cmux exports into every
    /// terminal it owns. With neither set the app's selected-workspace fallback is
    /// still the best available answer.
    static func tabs(_ arguments: [String]) -> [String] {
        var params: [String: Any] = [:]
        let environment = ProcessInfo.processInfo.environment
        if let surfaceID = nonEmpty(environment["CMUX_SURFACE_ID"]) {
            params["surface_id"] = surfaceID
        } else if let workspaceID = nonEmpty(environment["CMUX_WORKSPACE_ID"]) {
            params["workspace_id"] = workspaceID
        }
        return fetch(method: "browser.tab.list", params: params, mapping: identifier)
    }

    /// Theme names come off disk, not the socket, so the socket deadline does not
    /// apply: a large or slow (network-mounted, spun-down) theme directory would
    /// otherwise stall the shell for as long as the scan takes. The scan runs on a
    /// worker and the handler abandons it at the same 0.5s bound. The abandoned
    /// worker outlives the wait but not the process, which exits as soon as the
    /// candidates are printed.
    static func themes(_ arguments: [String]) -> [String] {
        let box = ThemeNamesBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = CMUXCLI(args: CommandLine.arguments).availableThemeNames()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return [] }
        return sanitized(box.value)
    }

    static func vms(_ arguments: [String]) -> [String] {
        fetch(method: "vm.list", mapping: identifier)
    }

    /// The listing key every entity uses, with `ref` preferred and `id` as the
    /// fallback. `vm.list` publishes only `id`, and any list item that carries an
    /// `id` without a `ref` would otherwise be dropped from the candidate set --
    /// the same `id ?? ref` shape the rest of the CLI reads these lists with.
    private static func identifier(_ item: [String: Any]) -> String? {
        (item["ref"] as? String) ?? (item["id"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Candidates are printed one per line, so a value carrying a newline would
    /// split into two bogus candidates and any other control character can drive
    /// the completing terminal. Drop those values instead of emitting them: a
    /// name that cannot be represented in the protocol cannot be completed either.
    private static func sanitized(_ candidates: [String]) -> [String] {
        candidates.filter { candidate in
            !candidate.isEmpty && !candidate.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            }
        }
    }

    /// Returns candidates, or an empty array for every failure mode.
    private static func fetch(
        method: String,
        params: [String: Any] = [:],
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
            let payload = try client.sendV2(
                method: method,
                params: params,
                responseTimeout: responseTimeout
            )
            guard let listName = method.split(separator: ".").dropLast().last.map({ "\($0)s" }),
                  let items = payload[listName] as? [[String: Any]] else {
                return []
            }
            return sanitized(items.compactMap(mapping))
        } catch {
            return []
        }
    }

    private static func remainingTimeout(until deadline: Date) -> TimeInterval? {
        let remaining = deadline.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }
}

/// Carries the worker's result back to `themes` across the semaphore.
private final class ThemeNamesBox: @unchecked Sendable {
    var value: [String] = []
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
