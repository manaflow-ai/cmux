public import Foundation

/// Transcript-scan substrate: runs `rg` to pre-filter candidate files for a
/// needle and reads bounded file heads, used by session/transcript indexing.
///
/// This is an instance service, not a static-utility namespace. The ripgrep
/// executable path is resolved through an injected `ripgrepPathResolver` closure
/// so the scanner stays decoupled from app-side ripgrep-path resolution (and so
/// the resolution can be faked in tests). Pass an explicit `ripgrepPath` to
/// override the resolver per call.
///
/// ```swift
/// let scanner = RipgrepFileScanner(ripgrepPathResolver: { resolvedRipgrepPath() })
/// let urls = await scanner.matchingPaths(needle: "foo", root: dir, fileGlob: "*.jsonl")
/// ```
public struct RipgrepFileScanner: Sendable {
    private let ripgrepPathResolver: @Sendable () -> String?

    /// Create a scanner.
    /// - Parameter ripgrepPathResolver: Resolves the `rg` executable path, or
    ///   `nil` when ripgrep is unavailable (the caller then falls back to a
    ///   Foundation scan). Defaults to always-unavailable.
    public init(ripgrepPathResolver: @escaping @Sendable () -> String? = { nil }) {
        self.ripgrepPathResolver = ripgrepPathResolver
    }

    /// Run `rg --files-with-matches --ignore-case --fixed-strings` for `needle`
    /// under `root`, restricted to `glob` (e.g. `*.jsonl`). Returns matched file
    /// URLs, or nil if rg isn't available or the run failed (caller falls back).
    ///
    /// Async by design so we can wire cancellation: when the awaiting Task is
    /// cancelled (e.g. user types another key), `onCancel` signals the launched
    /// rg process instead of letting it grind to completion.
    public func matchingPaths(
        needle: String, root: String, fileGlob: String, ripgrepPath: String? = nil
    ) async -> [URL]? {
        guard let rg = ripgrepPath ?? ripgrepPathResolver() else { return nil }
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
        let cancellation = SessionIndexRipgrepCancellation()
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

    /// Read up to `byteCap` bytes from the start of the file as UTF-8.
    ///
    /// Used to cheaply peek at the head of a transcript (e.g. the first
    /// `session_meta` line) without reading the whole file.
    public func readFileHead(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
