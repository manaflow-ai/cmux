internal import Foundation

struct MacKeepAwakeStatusParser {
    /// Parse `pmset -g assertions` output into a keep-awake status.
    ///
    /// `pmset -g assertions` prints a system-wide summary, then a "Listed by
    /// owning process" section with one line per process/assertion type:
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
    /// Owning-process lines provide attribution. System-wide counts provide
    /// fallback booleans when pmset cannot attribute a sleep-prevention count to
    /// a parseable process holder.
    func parse(pmsetAssertions output: String) -> MacKeepAwakeStatus {
        // Preserve first-seen order of pids while merging their assertion types.
        var typesByPID: [Int: [String]] = [:]
        var nameByPID: [Int: String] = [:]
        var detailByPID: [Int: String] = [:]
        var pidOrder: [Int] = []
        var inOwningSection = false
        var inSystemStatusSection = false
        var aggregatePreventsSystemSleep = false
        var aggregatePreventsDisplaySleep = false

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
                inSystemStatusSection = header.hasPrefix("assertion status system-wide")
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inSystemStatusSection,
               let aggregate = Self.parseSystemWideAssertionCountLine(trimmed),
               aggregate.count > 0 {
                if Self.systemSleepAssertionTypes.contains(aggregate.type) {
                    aggregatePreventsSystemSleep = true
                }
                if aggregate.type == Self.displaySleepAssertionType {
                    aggregatePreventsDisplaySleep = true
                }
                continue
            }
            guard inOwningSection else { continue }
            guard trimmed.hasPrefix("pid "), let parsed = Self.parsePmsetProcessLine(trimmed) else { continue }
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

        let holderPreventsSystem = holders.contains {
            !Self.systemSleepAssertionTypes.isDisjoint(with: Set($0.assertionTypes))
        }
        let holderPreventsDisplay = holders.contains {
            $0.assertionTypes.contains(Self.displaySleepAssertionType)
        }
        let preventsSystem = aggregatePreventsSystemSleep || holderPreventsSystem
        let preventsDisplay = aggregatePreventsDisplaySleep || holderPreventsDisplay
        let cmux = holders.contains { Self.isCmuxProcess($0.processName) }
        let caffeinate = holders.contains { Self.isCaffeinateProcess($0.processName) }

        return MacKeepAwakeStatus(
            keptAwake: preventsSystem || preventsDisplay,
            preventsSystemSleep: preventsSystem,
            preventsDisplaySleep: preventsDisplay,
            cmuxKeepingAwake: cmux,
            caffeinateRunning: caffeinate,
            holders: holders
        )
    }

    // MARK: - pmset assertion parsing helpers

    /// Assertion types that keep the whole system from sleeping.
    private static let systemSleepAssertionTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
    ]

    /// Assertion type that keeps the display awake (which also keeps the system
    /// awake while it is held).
    private static let displaySleepAssertionType = "PreventUserIdleDisplaySleep"

    /// Every assertion-type token recognized on an owning-process line.
    private static let knownAssertionTypes: Set<String> =
        systemSleepAssertionTypes.union([displaySleepAssertionType])

    /// Parse one system-wide count line, e.g. `PreventUserIdleSystemSleep     1`.
    private static func parseSystemWideAssertionCountLine(_ line: String) -> (type: String, count: Int)? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        let type = String(parts[0])
        guard knownAssertionTypes.contains(type),
              let count = Int(parts[1]) else {
            return nil
        }
        return (type, count)
    }

    /// True for the cmux app's own process (matches `cmux`, `cmux DEV …`, etc.).
    private static func isCmuxProcess(_ name: String) -> Bool {
        name.lowercased().contains("cmux")
    }

    /// True for the `caffeinate` command-line tool.
    private static func isCaffeinateProcess(_ name: String) -> Bool {
        name.lowercased() == "caffeinate"
    }

    /// Parse one owning-process line, e.g.
    /// `pid 42(caffeinate): [0x…] 00:13:25 PreventUserIdleSystemSleep named: "…"`.
    ///
    /// Returns the pid, process name, the known assertion types found on the line,
    /// and the quoted `named:` detail (if any). Lines that do not start with a
    /// `pid N(name):` head return `nil`.
    private static func parsePmsetProcessLine(
        _ line: String
    ) -> (pid: Int, name: String, types: [String], detail: String?)? {
        guard line.hasPrefix("pid ") else { return nil }
        guard let openParen = line.firstIndex(of: "("),
              let headEnd = line.range(
                of: "): ",
                options: [],
                range: openParen..<line.endIndex
              ) else { return nil }
        let closeParen = headEnd.lowerBound
        let pidStart = line.index(line.startIndex, offsetBy: 4)
        guard pidStart <= openParen else { return nil }
        let pidString = line[pidStart..<openParen].trimmingCharacters(in: .whitespaces)
        guard let pid = Int(pidString) else { return nil }
        let name = String(line[line.index(after: openParen)..<closeParen])

        // Assertion types: any known token appearing after the `pid N(name):` head.
        let remainder = line[headEnd.upperBound...]
        var types: [String] = []
        for token in remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let candidate = String(token)
            if knownAssertionTypes.contains(candidate) {
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
