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

    /// Read up to `byteCap` bytes from the end of the file as UTF-8.
    ///
    /// Used to find late-arriving events like pr-link without scanning the whole
    /// file. Trims the leading partial line, since the cap likely cuts mid-record.
    public func readFileTail(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return "" }
        if size == 0 { return "" }
        let cap = UInt64(byteCap)
        let offset: UInt64 = size > cap ? size - cap : 0
        do { try handle.seek(toOffset: offset) } catch { return "" }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        // Trim leading partial line (we likely cut mid-record).
        if offset > 0, let nl = data.firstIndex(of: 0x0a) {
            return String(data: data[(nl + 1)...], encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stream JSON-lines from the start of `url`. `body` returns true to stop early.
    /// Caps total bytes read at `maxBytes`.
    ///
    /// Reads in 64 KB chunks, splits on newline (`0x0a`), parses each non-empty
    /// line with `JSONSerialization` and hands the object to `body`; a trailing
    /// line with no terminating newline is flushed at EOF.
    public func forEachJSONLine(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024
        while totalRead < maxBytes {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: 0..<nl)
                leftover.removeSubrange(0..<(nl + 1))
                if lineData.isEmpty { continue }
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    if body(obj) { return }
                }
            }
        }
        // Flush trailing line if no newline at EOF.
        if !leftover.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: leftover) as? [String: Any] {
            _ = body(obj)
        }
    }

    /// Returns a usable user-prompt string from a Codex `user_message` /
    /// `response_item.input_text` payload, or nil when the message is just an
    /// envelope/system wrapper (`<environment_context>...`, `<user_instructions>`,
    /// `<permissions>`, AGENTS.md preamble) that we don't want to surface as a
    /// session title.
    public func realCodexUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let envelopePrefixes = [
            "<environment_context",
            "<user_instructions",
            "<permissions",
            "<system",
            "# AGENTS.md",
        ]
        for prefix in envelopePrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }
}
