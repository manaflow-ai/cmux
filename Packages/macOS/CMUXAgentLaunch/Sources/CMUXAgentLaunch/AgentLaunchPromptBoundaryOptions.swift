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
        if let modeEnd = promptBoundaryLaunchModeEnd(args, index: index) {
            index = modeEnd
            return true
        }
        guard let recoveryStart = postBoundaryRecoveryStart(args, index: index) else {
            index = args.count
            return true
        }
        var scan = recoveryStart
        var recovered: [String] = []
        while scan < args.count {
            guard let end = recoveredPostBoundaryOptionEnd(args, index: scan) else {
                break
            }
            recovered.append(contentsOf: args[scan..<end])
            scan = end
        }
        result.append(contentsOf: recovered)
        index = args.count
        return true
    }
}

private func promptBoundaryOption(_ arg: String, options: Set<String>) -> String? {
    if options.contains(arg) { return arg }
    guard let equals = arg.firstIndex(of: "=") else { return nil }
    let option = String(arg[..<equals])
    return options.contains(option) ? option : nil
}

func isOptionToken(_ arg: String) -> Bool {
    arg.hasPrefix("-") && arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
}

private func postBoundaryRecoveryStart(_ args: [String], index: Int) -> Int? {
    let arg = args[index]
    if arg.hasPrefix("--tmux=") { return nil }
    guard arg == "--tmux", index + 1 < args.count else { return nil }
    let value = args[index + 1]
    if !value.hasPrefix("-") && value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
        return index + 2
    }
    return nil
}

private func promptBoundaryLaunchModeEnd(_ args: [String], index: Int) -> Int? {
    let arg = args[index]
    if arg.hasPrefix("--tmux=") {
        let value = String(arg.dropFirst("--tmux=".count))
        return knownTmuxModeValues.contains(value) ? index + 1 : nil
    }
    guard arg == "--tmux", index + 1 < args.count else { return nil }
    return knownTmuxModeValues.contains(args[index + 1]) ? index + 2 : nil
}

private func recoveredPostBoundaryOptionEnd(_ args: [String], index: Int) -> Int? {
    guard index < args.count else { return nil }
    switch args[index] {
    case "--model", "--fallback-model":
        guard index + 1 < args.count, !isOptionToken(args[index + 1]) else { return nil }
        return index + 2
    case let option where option.hasPrefix("--model=") || option.hasPrefix("--fallback-model="):
        return index + 1
    case "--permission-mode":
        guard index + 1 < args.count,
              safePostBoundaryPermissionModes.contains(args[index + 1]) else { return nil }
        return index + 2
    case let option where option.hasPrefix("--permission-mode="):
        let value = String(option.dropFirst("--permission-mode=".count))
        return safePostBoundaryPermissionModes.contains(value) ? index + 1 : nil
    default:
        return nil
    }
}

private let knownTmuxModeValues: Set<String> = ["classic"]
private let safePostBoundaryPermissionModes: Set<String> = ["auto"]
