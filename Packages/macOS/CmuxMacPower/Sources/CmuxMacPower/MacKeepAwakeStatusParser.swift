internal import Foundation

/// Parses `pmset -g assertions` output into a structured ``MacKeepAwakeStatus``.
///
/// `pmset -g assertions` prints a system-wide summary, then a "Listed by owning
/// process" section with one line per (process, assertion type):
///
/// ```
/// Assertion status system-wide:
///    PreventUserIdleSystemSleep     1
///    ...
/// Listed by owning process:
///    pid 42(caffeinate): [0x000…04a0] 00:13:25 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
///    pid 88(cmux): [0x000…04a8] PreventUserIdleSystemSleep named: "cmux keep awake"
/// Kernel Assertions: 0x4=USB
///    id=500 level=255 0x4=USB …
/// ```
///
/// We read only the owning-process section — the precise, attributable truth —
/// merge multiple lines for the same pid, and derive the booleans from the set
/// of assertion types seen. The system-wide aggregate counts are intentionally
/// ignored because they cannot attribute "who" is keeping the Mac awake.
public enum MacKeepAwakeStatusParser {
    /// Assertion types that keep the whole system from sleeping.
    private static let systemSleepTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
    ]
    /// Assertion type that keeps the display awake (which also keeps the system
    /// awake while it is held).
    private static let displaySleepType = "PreventUserIdleDisplaySleep"
    /// Every assertion-type token we recognize on an owning-process line.
    private static let knownTypes: Set<String> =
        systemSleepTypes.union([displaySleepType])

    /// Parse raw `pmset -g assertions` stdout into a status snapshot.
    public static func parse(_ output: String) -> MacKeepAwakeStatus {
        // Preserve first-seen order of pids while merging their assertion types.
        var typesByPID: [Int: [String]] = [:]
        var nameByPID: [Int: String] = [:]
        var detailByPID: [Int: String] = [:]
        var pidOrder: [Int] = []
        var inOwningSection = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
            // Any non-indented line starts a new top-level section. We are inside
            // the owning-process list only while the most recent header was the
            // "Listed by owning process:" one; "Kernel Assertions:" and the
            // leading timestamp both reset the flag.
            if !isIndented {
                let header = line.trimmingCharacters(in: .whitespaces).lowercased()
                inOwningSection = header.hasPrefix("listed by owning process")
                continue
            }
            guard inOwningSection else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid "), let parsed = parseProcessLine(trimmed) else { continue }
            if typesByPID[parsed.pid] == nil {
                typesByPID[parsed.pid] = []
                nameByPID[parsed.pid] = parsed.name
                pidOrder.append(parsed.pid)
            }
            for type in parsed.types where !(typesByPID[parsed.pid]?.contains(type) ?? false) {
                typesByPID[parsed.pid]?.append(type)
            }
            if detailByPID[parsed.pid] == nil, let detail = parsed.detail {
                detailByPID[parsed.pid] = detail
            }
        }

        let holders: [MacPowerAssertionHolder] = pidOrder.compactMap { pid in
            guard let types = typesByPID[pid], !types.isEmpty else { return nil }
            return MacPowerAssertionHolder(
                pid: pid,
                processName: nameByPID[pid] ?? "",
                assertionTypes: types,
                detail: detailByPID[pid]
            )
        }

        let preventsSystem = holders.contains { !systemSleepTypes.isDisjoint(with: Set($0.assertionTypes)) }
        let preventsDisplay = holders.contains { $0.assertionTypes.contains(displaySleepType) }
        let cmux = holders.contains { isCmuxProcess($0.processName) }
        let caffeinate = holders.contains { isCaffeinateProcess($0.processName) }

        return MacKeepAwakeStatus(
            keptAwake: preventsSystem || preventsDisplay,
            preventsSystemSleep: preventsSystem,
            preventsDisplaySleep: preventsDisplay,
            cmuxKeepingAwake: cmux,
            caffeinateRunning: caffeinate,
            holders: holders
        )
    }

    /// True for the cmux app's own process (matches `cmux`, `cmux DEV …`, etc.).
    static func isCmuxProcess(_ name: String) -> Bool {
        name.lowercased().contains("cmux")
    }

    /// True for the `caffeinate` command-line tool.
    static func isCaffeinateProcess(_ name: String) -> Bool {
        name.lowercased() == "caffeinate"
    }

    /// Parse one owning-process line, e.g.
    /// `pid 42(caffeinate): [0x…] 00:13:25 PreventUserIdleSystemSleep named: "…"`.
    ///
    /// Returns the pid, process name, the known assertion types found on the
    /// line, and the quoted `named:` detail (if any). Lines that do not start
    /// with a `pid N(name):` head return `nil`.
    static func parseProcessLine(
        _ line: String
    ) -> (pid: Int, name: String, types: [String], detail: String?)? {
        guard line.hasPrefix("pid ") else { return nil }
        guard let openParen = line.firstIndex(of: "("),
              let closeParen = line[openParen...].firstIndex(of: ")") else { return nil }
        let pidStart = line.index(line.startIndex, offsetBy: 4)
        guard pidStart <= openParen else { return nil }
        let pidString = line[pidStart..<openParen].trimmingCharacters(in: .whitespaces)
        guard let pid = Int(pidString) else { return nil }
        let name = String(line[line.index(after: openParen)..<closeParen])

        // Assertion types: any known token appearing after the `pid N(name):` head.
        let remainder = line[closeParen...]
        var types: [String] = []
        for token in remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let candidate = String(token)
            if knownTypes.contains(candidate) {
                types.append(candidate)
            }
        }

        // Detail: text inside the first pair of quotes after `named:`.
        var detail: String?
        if let namedRange = line.range(of: "named:") {
            let after = line[namedRange.upperBound...]
            if let firstQuote = after.firstIndex(of: "\"") {
                let valueStart = after.index(after: firstQuote)
                if let secondQuote = after[valueStart...].firstIndex(of: "\"") {
                    detail = String(after[valueStart..<secondQuote])
                }
            }
        }
        return (pid, name, types, detail)
    }
}
