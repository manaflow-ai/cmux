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
        index += width
        if index < args.count, !isOptionToken(args[index]) {
            index += 1
        }
        var recovered: [String] = []
        while index < args.count {
            if args[index] == "--" {
                index = args.count
                return true
            }
            let option = optionName(args[index])
            guard policy.postPromptBoundaryOptions.contains(option),
                  let end = postBoundaryOptionEnd(args, index: index, option: option, policy: policy) else {
                index = args.count
                return true
            }
            recovered.append(contentsOf: args[index..<end])
            index = end
            if index < args.count, !isOptionToken(args[index]) {
                result.append(contentsOf: recovered)
                index = args.count
                return true
            }
        }
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

private func optionName(_ arg: String) -> String {
    guard let equals = arg.firstIndex(of: "=") else { return arg }
    return String(arg[..<equals])
}

private func postBoundaryOptionEnd(
    _ args: [String],
    index: Int,
    option: String,
    policy: AgentLaunchSanitizer.Policy
) -> Int? {
    if args[index].contains("=") { return index + 1 }
    if policy.valueOptions.contains(option) {
        guard index + 1 < args.count, !isOptionToken(args[index + 1]) else { return nil }
        return index + 2
    }
    return index + 1
}
