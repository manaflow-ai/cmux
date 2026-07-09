public import Foundation

/// Process-spawn ripgrep file-search capability: runs `rg` to pre-filter the
/// files that contain a needle, with cancellation wired to the awaiting Task,
/// plus a Foundation substring-scan fallback for callers that cannot use rg.
///
/// The `rg` executable path is injected (resolved app-side, where the
/// configured-path policy lives); a nil path means rg is unavailable and the
/// search returns nil so the caller falls back to its own scan.
public struct RipgrepFileSearch: Sendable {
    /// Path to `rg` (ripgrep), or nil when rg is unavailable.
    private let ripgrepPath: String?

    /// - Parameter ripgrepPath: resolved path to the `rg` executable, or nil.
    public init(ripgrepPath: String?) {
        self.ripgrepPath = ripgrepPath
    }

    /// Run `rg --files-with-matches --ignore-case --fixed-strings` for `needle`
    /// under `root`, restricted to `glob` (e.g. `*.jsonl`). Returns matched file
    /// URLs, or nil if rg isn't available or the run failed (caller falls back).
    ///
    /// Async by design so we can wire cancellation: when the awaiting Task is
    /// cancelled (e.g. user types another key), `onCancel` signals the launched
    /// rg process instead of letting it grind to completion.
    public func matchingPaths(
        needle: String, root: String, fileGlob: String
    ) async -> [URL]? {
        guard let rg = ripgrepPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = [
            "--files-with-matches",
            "--ignore-case",
            "--fixed-strings",
            "--no-messages",
            "--no-ignore",
            "--hidden",
            "--glob", fileGlob,
            "--",
            needle,
            root,
        ]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr to /dev/null so its pipe can never deadlock either.
        if let nullDev = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullDev
        }
        let cancellation = RipgrepProcessCancellation()
        process.terminationHandler = { process in
            cancellation.markFinished(processIdentifier: process.processIdentifier)
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [] }
            do {
                try process.run()
            } catch {
                if Task.isCancelled { return [] }
                return nil as [URL]?
            }
            cancellation.markStarted(processIdentifier: process.processIdentifier)
            if Task.isCancelled {
                cancellation.cancel()
            }
            // Drain stdout BEFORE waitUntilExit. With many matches rg writes
            // more than the ~64 KB pipe buffer; reading until EOF lets rg
            // make progress and EOF arrives when rg closes its stdout on exit.
            // Once the pipe read returns, the process is already exiting,
            // so waitUntilExit is essentially instant — we just need it to make
            // terminationStatus observable. (Setting terminationHandler here
            // would race: if rg already exited, the handler is registered too
            // late and never fires → deadlock.)
            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            cancellation.markFinished(processIdentifier: process.processIdentifier)
            if Task.isCancelled { return [] }
            // rg exit codes: 0 = matches, 1 = no matches, 2 = error/terminated.
            switch process.terminationStatus {
            case 0:
                guard let str = String(data: data, encoding: .utf8) else { return nil as [URL]? }
                return str.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { URL(fileURLWithPath: String($0)) }
            case 1:
                return []
            default:
                return nil
            }
        } onCancel: {
            // Fires synchronously when the awaiting Task is cancelled. SIGTERM
            // closes stdout, lets the pipe read return, and unblocks the
            // body so this call can complete cleanly.
            cancellation.cancel()
        }
    }

    /// Foundation substring scan: returns whether `url`'s contents contain
    /// `needle` (case-insensitive, literal). Used as the rg-less fallback.
    public static func fileContainsNeedle(url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
    }
}
