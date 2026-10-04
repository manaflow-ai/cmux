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

    /// Candidates must agree with the command they complete, so an explicit
    /// `--workspace`/`--window` already typed on the line scopes the listing.
    /// Without params the app answers for its *selected* workspace, which is not
    /// necessarily the one the user is targeting.
    @Sendable static func workspaces(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "workspace.list", params: selectors(["window"], in: arguments), mapping: identifier)
    }

    @Sendable static func surfaces(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "surface.list", params: selectors(["window", "workspace"], in: arguments), mapping: identifier)
    }

    @Sendable static func windows(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "window.list", mapping: identifier)
    }

    @Sendable static func panes(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "pane.list", params: selectors(["window", "workspace"], in: arguments), mapping: identifier)
    }

    @Sendable static func panels(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "surface.list", params: selectors(["window", "workspace"], in: arguments), mapping: identifier)
    }

    /// Browser tabs live in one workspace, so this is the one handler that has to
    /// say which. Without params the app answers for its *selected* workspace,
    /// which is not necessarily the one the completing shell sits in; the caller's
    /// own surface and workspace come from the environment cmux exports into every
    /// terminal it owns. With neither set the app's selected-workspace fallback is
    /// still the best available answer.
    @Sendable static func tabs(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        var params = selectors(["surface", "workspace"], in: arguments)
        let environment = ProcessInfo.processInfo.environment
        // An explicit selector on the line wins over the caller's environment.
        if !params.isEmpty {
            // keep as typed
        } else if let surfaceID = nonEmpty(environment["CMUX_SURFACE_ID"]) {
            params["surface_id"] = surfaceID
        } else if let workspaceID = nonEmpty(environment["CMUX_WORKSPACE_ID"]) {
            params["workspace_id"] = workspaceID
        }
        return fetch(arguments, method: "browser.tab.list", params: params, mapping: identifier)
    }

    /// Theme names come off disk, not the socket, so the socket deadline does not
    /// apply: a large or slow (network-mounted, spun-down) theme directory would
    /// otherwise stall the shell for as long as the scan takes. The scan runs on a
    /// worker and the handler abandons it at the same 0.5s bound. The abandoned
    /// worker outlives the wait but not the process, which exits as soon as the
    /// candidates are printed.
    @Sendable static func themes(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        let box = ThemeNamesBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = CMUXCLI(args: CommandLine.arguments).availableThemeNames()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return [] }
        return sanitized(box.value)
    }

    @Sendable static func vms(_ arguments: [String], _ index: Int = 0, _ prefix: String = "") -> [String] {
        fetch(arguments, method: "vm.list", mapping: identifier)
    }

    /// The listing key every entity uses, with `ref` preferred and `id` as the
    /// fallback. `vm.list` publishes only `id`, and any list item that carries an
    /// `id` without a `ref` would otherwise be dropped from the candidate set --
    /// the same `id ?? ref` shape the rest of the CLI reads these lists with.
    private static func identifier(_ item: [String: Any]) -> String? {
        (item["ref"] as? String) ?? (item["id"] as? String)
    }

    /// Reads `--name value` and `--name=value` from the shell words, last one
    /// winning, and maps each to the `<name>_id` RPC param. A flag with no value
    /// yet, or whose next word is another flag, contributes nothing.
    private static func selectors(_ names: [String], in words: [String]) -> [String: Any] {
        var params: [String: Any] = [:]
        for name in names {
            let flag = "--\(name)"
            for (index, word) in words.enumerated() {
                var value: String?
                if word == flag, index + 1 < words.count {
                    value = words[index + 1]
                } else if word.hasPrefix(flag + "=") {
                    value = String(word.dropFirst(flag.count + 1))
                }
                if let value = nonEmpty(value), !value.hasPrefix("-") {
                    params["\(name)_id"] = value
                }
            }
        }
        return params
    }

    /// The root `--socket` and `--password` typed before the command name, last
    /// one winning. Like `CMUXCLI.run`, which reads global options only ahead of
    /// the command, so completion connects where the completed command will.
    /// `words[0]` is the executable. Bash splits `--socket=<path>` at the `=` in
    /// COMP_WORDS, so a lone `=` between a flag and its value is skipped.
    private static func connectionOptions(in words: [String]) -> (socket: String?, password: String?) {
        var socket: String?
        var password: String?
        var index = 1
        while index < words.count {
            let (name, inlineValue) = CMUXCLI.splitGlobalOption(words[index])
            if CMUXCLI.valueTakingGlobalOptionNames.contains(name) {
                var valueIndex = index + 1
                if inlineValue == nil, valueIndex < words.count, words[valueIndex] == "=" {
                    valueIndex += 1
                }
                let value = inlineValue ?? (valueIndex < words.count ? words[valueIndex] : nil)
                switch name {
                case "--socket": socket = nonEmpty(value) ?? socket
                case "--password": password = nonEmpty(value) ?? password
                default: break
                }
                index = inlineValue == nil ? valueIndex + 1 : index + 1
            } else if name == "--json" {
                index += 1
            } else {
                break
            }
        }
        return (socket, password)
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
        _ words: [String],
        method: String,
        params: [String: Any] = [:],
        mapping: ([String: Any]) -> String?
    ) -> [String] {
        do {
            let deadline = Date.now.addingTimeInterval(timeout)
            let processEnvironment = ProcessInfo.processInfo.environment
            let typed = connectionOptions(in: words)
            // Same precedence as `CMUXCLI.run`: --socket, then CMUX_SOCKET_PATH,
            // then the default path.
            let environmentSocketPath = typed.socket == nil
                ? try CLISocketEnvironment.socketPath(in: processEnvironment)
                : nil
            let bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
            let requestedSocketPath = typed.socket ?? environmentSocketPath ?? CLISocketPathResolver.defaultSocketPath(
                bundleIdentifier: bundleIdentifier,
                environment: processEnvironment
            )
            let source: CLISocketPathSource = typed.socket != nil
                ? .explicitFlag
                : environmentSocketPath == nil ? .implicitDefault : .environment
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
                explicitPassword: typed.password,
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
    /// Shell words the handler scopes its listing by, as ArgumentParser's
    /// completion callback would pass them.
    /// `.captureForPassthrough`, not `.remaining`: the words carry flags such as
    /// `--workspace` that this command does not declare.
    @Argument(parsing: .captureForPassthrough) var words: [String] = []

    func run() throws {
        let candidates: [String]
        switch kind {
        case "workspaces": candidates = CompletionCandidates.workspaces(words)
        case "surfaces": candidates = CompletionCandidates.surfaces(words)
        case "windows": candidates = CompletionCandidates.windows(words)
        case "panes": candidates = CompletionCandidates.panes(words)
        case "panels": candidates = CompletionCandidates.panels(words)
        case "tabs": candidates = CompletionCandidates.tabs(words)
        case "themes": candidates = CompletionCandidates.themes(words)
        case "vms": candidates = CompletionCandidates.vms(words)
        default: candidates = []
        }

        for candidate in candidates {
            print(candidate)
        }
    }
}
