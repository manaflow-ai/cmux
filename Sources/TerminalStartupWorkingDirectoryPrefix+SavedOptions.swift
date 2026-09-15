import CMUXAgentLaunch
import Foundation

extension TerminalStartupWorkingDirectoryPrefix {
    /// Finds cwd options that duplicate the saved directory using the agent's option semantics.
    static func savedWorkingDirectoryOptionRanges(
        in words: [ShellWordRange],
        workingDirectory: String,
        agentKind: String?
    ) -> [Range<String.Index>] {
        let optionPolicy = AgentWorkingDirectoryOptionPolicy(agentKind: agentKind)
        let valueOptions = optionPolicy.valueOptions
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var ranges: [Range<String.Index>] = []
        var index = 0
        while index < words.count {
            let arg = words[index].value
            if arg == "--" { break }
            if valueOptions.contains(arg),
               index + 1 < words.count,
               workingDirectoryValue(words[index + 1].value, matches: workingDirectory) {
                ranges.append(words[index].range.lowerBound..<words[index + 1].range.upperBound)
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                let value = String(arg.dropFirst(prefix.count))
                if workingDirectoryValue(value, matches: workingDirectory) {
                    ranges.append(words[index].range)
                    index += 1
                    continue
                }
            }
            if let option = optionPolicy.attachedShortValueOptions.first(where: {
                arg.count > $0.count && arg.hasPrefix($0)
            }) {
                let value = String(arg.dropFirst(option.count))
                if workingDirectoryValue(value, matches: workingDirectory) {
                    ranges.append(words[index].range)
                    index += 1
                    continue
                }
            }
            index += 1
        }
        return ranges
    }

    private static func workingDirectoryValue(_ value: String, matches workingDirectory: String) -> Bool {
        guard value == workingDirectory else {
            return (value as NSString).expandingTildeInPath == (workingDirectory as NSString).expandingTildeInPath
        }
        return true
    }
}
