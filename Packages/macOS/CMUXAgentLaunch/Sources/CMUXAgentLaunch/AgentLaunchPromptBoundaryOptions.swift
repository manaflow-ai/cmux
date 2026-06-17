import Foundation

extension AgentLaunchSanitizer {
    static func consumePromptBoundaryOption(
        _ arg: String,
        args: [String],
        index: inout Int,
        width: Int,
        policy: Policy,
        result: inout [String]
    ) -> Bool? {
        guard promptBoundaryOption(arg, options: policy.promptBoundaryOptions) != nil else { return false }
        if let modeEnd = promptBoundaryModeEnd(args, index: index) {
            index = modeEnd
            return true
        }
        index = args.count
        return true
    }
}

private func promptBoundaryOption(_ arg: String, options: Set<String>) -> String? {
    options.contains(arg) ? arg : nil
}

func isOptionToken(_ arg: String) -> Bool {
    arg.hasPrefix("-") && arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
}

private func promptBoundaryModeEnd(_ args: [String], index: Int) -> Int? {
    guard args[index] == "--tmux",
          index + 1 < args.count,
          knownTmuxModeValues.contains(args[index + 1]) else {
        return nil
    }
    return index + 2
}

private let knownTmuxModeValues: Set<String> = [
    "classic",
]
