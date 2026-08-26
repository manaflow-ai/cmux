import Foundation

/// Builds Prime Agent's session-file-based resume command.
///
/// Prime exposes both opaque session IDs and durable session files, but
/// `prime-agent --resume` needs an absolute file path for deterministic cmux
/// restore. Keeping this provider-specific parsing separate also prevents the
/// shared resume builder from growing a second option parser.
public enum PrimeAgentResumeArgv {
    /// Returns the executable token that should be used when replaying a
    /// captured Prime launch. JavaScript runtimes are implementation details;
    /// restore through Prime's public launcher instead of rendering
    /// `node --resume ...` (which the runtime would reject).
    public static func resumeExecutable(
        executablePath: String?,
        arguments: [String]
    ) -> String {
        let capturedExecutable = normalized(executablePath)
            ?? normalized(arguments.first)
            ?? "prime-agent"
        // A PID-derived capture may already have passed through the generic
        // sanitizer, which intentionally drops the runtime's script token.
        // Once the launch is known to be a JavaScript runtime, replaying
        // `<runtime> --resume ...` is never valid; use Prime's public launcher
        // even when the script is no longer present in the sanitized argv.
        return isJavaScriptRuntime(capturedExecutable) ? "prime-agent" : capturedExecutable
    }

    /// Preserves safe interactive options from a captured Prime launch,
    /// dropping the runtime/script wrapper and all session selectors.
    public static func preservedArguments(
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let capturedExecutable = normalized(executablePath)
            ?? normalized(arguments.first)
            ?? "prime-agent"
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        let replayTail = replayTail(capturedExecutable: capturedExecutable, tail: tail)
        return AgentLaunchSanitizer.preservedArguments(kind: "prime-agent", args: replayTail)
    }

    /// Builds a deterministic Prime session-file resume argv.
    public static func build(
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        let executable = resumeExecutable(
            executablePath: executablePath,
            arguments: arguments
        )
        let sessionFile = capturedSessionFile(from: tail)
            ?? (sessionId.hasPrefix("/") ? sessionId : nil)
        guard let sessionFile,
              !sessionFile.isEmpty,
              sessionFile.hasPrefix("/"),
              !sessionFile.hasSuffix("/") else {
            return nil
        }
        guard let preserved = preservedArguments(
            executablePath: executablePath,
            arguments: arguments
        ) else {
            return nil
        }
        return [executable, "--resume", sessionFile] + preserved
    }

    private static func replayTail(capturedExecutable: String, tail: [String]) -> [String] {
        guard isJavaScriptRuntime(capturedExecutable),
              let scriptIndex = tail.firstIndex(where: looksLikePrimeAgentScript) else {
            return tail
        }
        // Runtime flags before the script (for example `node --no-warnings`)
        // are not Prime options and must not be replayed.
        return Array(tail.dropFirst(scriptIndex + 1))
    }

    private static func capturedSessionFile(from arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let candidate: String
            if argument == "--resume", index + 1 < arguments.count {
                candidate = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else if argument.hasPrefix("--resume=") {
                candidate = String(argument.dropFirst("--resume=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            guard candidate.hasPrefix("/"), !candidate.hasSuffix("/") else { continue }
            return candidate
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isJavaScriptRuntime(_ value: String) -> Bool {
        ["node", "bun", "deno", "tsx", "ts-node"].contains(
            (value as NSString).lastPathComponent.lowercased()
        )
    }

    private static func looksLikePrimeAgentScript(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/").lowercased()
        let basename = (normalized as NSString).lastPathComponent
        let knownEntrypoint = ["cli.js", "cli.ts", "index.js", "index.ts"].contains(basename)
        let hasPrimePackageMarker = normalized.contains("/.prime/agent/")
            || normalized.contains("/prime-agent/")
            || normalized.contains("/@earendil-works/pi-coding-agent/")
        let hasCodingAgentMarker = normalized.contains("/coding-agent/")
            || normalized.contains("/pi-coding-agent/")
            || knownEntrypoint
        return hasPrimePackageMarker && hasCodingAgentMarker
    }
}
