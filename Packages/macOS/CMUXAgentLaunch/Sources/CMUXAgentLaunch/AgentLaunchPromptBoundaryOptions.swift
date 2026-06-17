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
