import Darwin
import Foundation

// MARK: - One "Next:" line for a person at a terminal

extension CMUXCLI {
    /// Whether this invocation may print a "Next:" line: only for a person, so
    /// never when stdout or stderr is piped. `CMUX_NO_HINTS=1` turns every hint
    /// off; `CMUX_CLI_HINTS=1` turns them on without a terminal (tests, demos).
    static func cliTeachingHintsEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["CMUX_NO_HINTS"].map(Self.isTruthyHintFlag) == true { return false }
        if environment["CMUX_CLI_HINTS"].map(Self.isTruthyHintFlag) == true { return true }
        return isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1
    }

    private static func isTruthyHintFlag(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The single next step after a bare `cmux vm` lists machines: open the
    /// first running machine's shell, or wake the first one when none runs.
    /// The machine is named by its label, which every `cmux vm` verb accepts,
    /// so the command copies and runs as-is.
    /// - Parameter machines: The listed machines as (address, state), in list order.
    /// - Returns: The line without a trailing newline, or nil for an empty list.
    static func vmBareListNextLine(machines: [(address: String, state: String)]) -> String? {
        guard !machines.isEmpty else { return nil }
        if let running = machines.first(where: { $0.state.lowercased() == "running" }) {
            return String(
                format: String(localized: "cli.vm.next.open", defaultValue: "Next: cmux vm open %@   open its shell here"),
                vmShellWord(running.address)
            )
        }
        if let paused = machines.first(where: { $0.state.lowercased() == "paused" }) {
            return String(
                format: String(localized: "cli.vm.next.resume", defaultValue: "Next: cmux vm resume %@   wake it"),
                vmShellWord(paused.address)
            )
        }
        return nil
    }

    /// Prints one "Next:" line to stderr when hints are on, so stdout stays the
    /// table scripts parse.
    static func printCLITeachingHint(_ line: String?) {
        guard let line, cliTeachingHintsEnabled() else { return }
        cliWriteStderr(line + "\n")
    }

    /// Quotes an address a shell would split; labels like `brave-otter` pass.
    private static func vmShellWord(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
