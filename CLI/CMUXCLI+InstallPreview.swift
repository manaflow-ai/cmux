import CmuxFoundation
import Darwin
import Foundation

extension CMUXCLI {
    private enum AnsiStyle {
        static func reset(_ tty: Bool) -> String { tty ? "\u{001B}[0m" : "" }
        static func bold(_ tty: Bool) -> String { tty ? "\u{001B}[1m" : "" }
        static func dim(_ tty: Bool) -> String { tty ? "\u{001B}[2m" : "" }
        static func red(_ tty: Bool) -> String { tty ? "\u{001B}[31m" : "" }
        static func green(_ tty: Bool) -> String { tty ? "\u{001B}[32m" : "" }
        static func yellow(_ tty: Bool) -> String { tty ? "\u{001B}[33m" : "" }
        static func magenta(_ tty: Bool) -> String { tty ? "\u{001B}[35m" : "" }
        static func cyan(_ tty: Bool) -> String { tty ? "\u{001B}[36m" : "" }
    }

    /// Prints a colored diff preview framed with the target path both
    /// above and below the diff. Every changed line is prefixed with
    /// `+` (addition) or `-` (deletion) and colored accordingly so the
    /// user can see at a glance what's being added/removed. A summary
    /// line above the diff counts adds/deletes so users who pipe the
    /// output into tee/less still see the shape of the change.
    static func printInstallPreview(
        path: String,
        oldContent: String,
        newContent: String,
        fallbackContent: String
    ) {
        let tty = isatty(fileno(stdout)) != 0
        let verb = oldContent.isEmpty ? "create" : "update"
        let header = AnsiStyle.bold(tty)
            + "─── Will \(verb) \(path) ───" + AnsiStyle.reset(tty)
        let footer = AnsiStyle.bold(tty)
            + "─── The above will be written to \(path) ───" + AnsiStyle.reset(tty)

        print("")
        print(header)

        if oldContent == newContent {
            print(AnsiStyle.dim(tty) + "(no changes — file already matches target)" + AnsiStyle.reset(tty))
            print(footer)
            return
        }

        if let diff = unifiedDiff(old: oldContent, new: newContent), !diff.isEmpty {
            let (adds, dels) = countAddDeleteLines(diff)
            let summary = AnsiStyle.bold(tty)
                + AnsiStyle.green(tty) + "+\(adds) additions" + AnsiStyle.reset(tty)
                + AnsiStyle.bold(tty) + ", "
                + AnsiStyle.red(tty) + "-\(dels) deletions" + AnsiStyle.reset(tty)
            print(summary)
            print("")
            print(colorizeDiff(diff, tty: tty))
        } else {
            // Diff unavailable (binary `/usr/bin/diff` missing, or temp-file
            // write failed). Fall back to full pretty-printed content.
            print(AnsiStyle.bold(tty) + "(diff unavailable — full content follows)" + AnsiStyle.reset(tty))
            for line in fallbackContent.split(separator: "\n", omittingEmptySubsequences: false) {
                let plus = AnsiStyle.green(tty) + AnsiStyle.bold(tty) + "+" + AnsiStyle.reset(tty)
                print("\(plus) " + jsonHighlight(String(line), tty: tty))
            }
        }
        print(footer)
    }

    /// Counts added and deleted lines in a unified-diff body, ignoring
    /// file header lines (`+++ …`, `--- …`).
    private static func countAddDeleteLines(_ diff: String) -> (adds: Int, dels: Int) {
        var adds = 0
        var dels = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { adds += 1 }
            if line.hasPrefix("-") { dels += 1 }
        }
        return (adds, dels)
    }

    /// Shells out to `/usr/bin/diff -u` against two temp files. Returns
    /// nil if diff isn't available or both inputs are identical.
    private static func unifiedDiff(old: String, new: String) -> String? {
        if old == new { return "" }
        let tempDir = FileManager.default.temporaryDirectory
        let oldURL = tempDir.appendingPathComponent("cmux-old-\(UUID().uuidString)")
        let newURL = tempDir.appendingPathComponent("cmux-new-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }
        do {
            try old.write(to: oldURL, atomically: true, encoding: .utf8)
            try new.write(to: newURL, atomically: true, encoding: .utf8)
        } catch { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", oldURL.path, newURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        var output = Data()
        let outputLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                outputLock.lock()
                output.append(data)
                outputLock.unlock()
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        do {
            try cliRunProcess(process)
        } catch { return nil }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
        if !remaining.isEmpty {
            outputLock.lock()
            output.append(remaining)
            outputLock.unlock()
        }
        // diff exits with 1 on differences; that's fine.
        outputLock.lock()
        let data = output
        outputLock.unlock()
        return String(data: data, encoding: .utf8)
    }

    /// Colors a unified diff: file headers dim, hunks cyan, additions
    /// bright-green-bold, deletions bright-red-bold, context uncolored.
    /// Non-tty output still retains the leading +/- markers so the
    /// change shape is obvious even when piped into a file or pager.
    private static func colorizeDiff(_ diff: String, tty: Bool) -> String {
        var out: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("+++") || s.hasPrefix("---") {
                out.append(AnsiStyle.dim(tty) + s + AnsiStyle.reset(tty))
            } else if s.hasPrefix("@@") {
                out.append(AnsiStyle.cyan(tty) + s + AnsiStyle.reset(tty))
            } else if s.hasPrefix("+") {
                out.append(AnsiStyle.bold(tty) + AnsiStyle.green(tty) + s + AnsiStyle.reset(tty))
            } else if s.hasPrefix("-") {
                out.append(AnsiStyle.bold(tty) + AnsiStyle.red(tty) + s + AnsiStyle.reset(tty))
            } else {
                out.append(s)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Tiny JSON syntax highlighter. Strings cyan; numbers yellow;
    /// booleans/null magenta. Keys stay uncolored because we'd need a
    /// lookahead parser to reliably distinguish them from string values.
    private static func jsonHighlight(_ json: String, tty: Bool) -> String {
        guard tty else { return json }
        var out = ""
        out.reserveCapacity(json.count + 32)
        var i = json.startIndex
        while i < json.endIndex {
            let c = json[i]
            if c == "\"" {
                // Scan to closing quote, honoring escapes.
                let start = i
                i = json.index(after: i)
                while i < json.endIndex {
                    let ch = json[i]
                    if ch == "\\", json.index(after: i) < json.endIndex {
                        i = json.index(i, offsetBy: 2)
                        continue
                    }
                    if ch == "\"" {
                        i = json.index(after: i)
                        break
                    }
                    i = json.index(after: i)
                }
                let lit = String(json[start..<i])
                out += AnsiStyle.cyan(tty) + lit + AnsiStyle.reset(tty)
                continue
            }
            if c.isNumber || (c == "-" && json.index(after: i) < json.endIndex && json[json.index(after: i)].isNumber) {
                let start = i
                while i < json.endIndex, let ch = Optional(json[i]),
                      ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                    i = json.index(after: i)
                }
                out += AnsiStyle.yellow(tty) + String(json[start..<i]) + AnsiStyle.reset(tty)
                continue
            }
            if json[i...].hasPrefix("true") || json[i...].hasPrefix("false") || json[i...].hasPrefix("null") {
                let token = json[i...].hasPrefix("false") ? "false"
                    : (json[i...].hasPrefix("true") ? "true" : "null")
                out += AnsiStyle.magenta(tty) + token + AnsiStyle.reset(tty)
                i = json.index(i, offsetBy: token.count)
                continue
            }
            out.append(c)
            i = json.index(after: i)
        }
        return out
    }
}
