internal import Foundation

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
/// Only the owning-process section is read: the precise, attributable truth.
/// Multiple lines for the same pid are merged, and the booleans are derived
/// from the assertion types seen. The system-wide aggregate counts are ignored
/// because they cannot attribute who is keeping the Mac awake.
func macParseKeepAwakeStatus(pmsetAssertions output: String) -> MacKeepAwakeStatus {
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
           let aggregate = macParseSystemWideAssertionCountLine(trimmed),
           aggregate.count > 0 {
            if macSystemSleepAssertionTypes.contains(aggregate.type) {
                aggregatePreventsSystemSleep = true
            }
            if aggregate.type == macDisplaySleepAssertionType {
                aggregatePreventsDisplaySleep = true
            }
            continue
        }
        guard inOwningSection else { continue }
        guard trimmed.hasPrefix("pid "), let parsed = macParsePmsetProcessLine(trimmed) else { continue }
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

    let holderPreventsSystem = holders.contains { !macSystemSleepAssertionTypes.isDisjoint(with: Set($0.assertionTypes)) }
    let holderPreventsDisplay = holders.contains { $0.assertionTypes.contains(macDisplaySleepAssertionType) }
    let preventsSystem = aggregatePreventsSystemSleep || holderPreventsSystem
    let preventsDisplay = aggregatePreventsDisplaySleep || holderPreventsDisplay
    let cmux = holders.contains { macIsCmuxProcess($0.processName) }
    let caffeinate = holders.contains { macIsCaffeinateProcess($0.processName) }

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
//
// File-scoped helpers for ``macParseKeepAwakeStatus(pmsetAssertions:)``.

/// Assertion types that keep the whole system from sleeping.
private let macSystemSleepAssertionTypes: Set<String> = [
    "PreventUserIdleSystemSleep",
    "PreventSystemSleep",
]
/// Assertion type that keeps the display awake (which also keeps the system
/// awake while it is held).
private let macDisplaySleepAssertionType = "PreventUserIdleDisplaySleep"
/// Every assertion-type token recognized on an owning-process line.
private let macKnownAssertionTypes: Set<String> =
    macSystemSleepAssertionTypes.union([macDisplaySleepAssertionType])

/// Parse one system-wide count line, e.g. `PreventUserIdleSystemSleep     1`.
private func macParseSystemWideAssertionCountLine(_ line: String) -> (type: String, count: Int)? {
    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2 else { return nil }
    let type = String(parts[0])
    guard macKnownAssertionTypes.contains(type),
          let count = Int(parts[1]) else {
        return nil
    }
    return (type, count)
}

/// True for the cmux app's own process (matches `cmux`, `cmux DEV …`, etc.).
private func macIsCmuxProcess(_ name: String) -> Bool {
    name.lowercased().contains("cmux")
}

/// True for the `caffeinate` command-line tool.
private func macIsCaffeinateProcess(_ name: String) -> Bool {
    name.lowercased() == "caffeinate"
}

/// Parse one owning-process line, e.g.
/// `pid 42(caffeinate): [0x…] 00:13:25 PreventUserIdleSystemSleep named: "…"`.
///
/// Returns the pid, process name, the known assertion types found on the line,
/// and the quoted `named:` detail (if any). Lines that do not start with a
/// `pid N(name):` head return `nil`.
private func macParsePmsetProcessLine(
    _ line: String
) -> (pid: Int, name: String, types: [String], detail: String?)? {
    guard line.hasPrefix("pid ") else { return nil }
    guard let openParen = line.firstIndex(of: "("),
          let headEnd = line.range(of: "): ", options: [], range: openParen..<line.endIndex) else { return nil }
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
        if macKnownAssertionTypes.contains(candidate) {
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
