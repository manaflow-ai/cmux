import Foundation

extension AgentLaunchSanitizer {
    static func preserveOptions(_ args: [String], policy: Policy) -> [String]? {
        var result: [String] = []
        var index = 0
        var consumedFirstPositional = false
        var sawPositional = false
        var sawOptionBeforePositional = false
        var skippingResumePositionals = false

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                break
            }

            if !arg.hasPrefix("-") || arg == "-" {
                let previousIndex = index
                guard consumePositional(
                    arg,
                    policy: policy,
                    index: &index,
                    result: &result,
                    consumedFirstPositional: &consumedFirstPositional,
                    sawPositional: &sawPositional,
                    sawOptionBeforePositional: sawOptionBeforePositional,
                    skippingResumePositionals: &skippingResumePositionals
                ) else { return nil }
                if index > previousIndex {
                    continue
                }
                break
            }
            sawOptionBeforePositional = true

            if shouldDropOption(arg, droppedOptions: policy.rejectOptions) {
                return nil
            }

            if policy.droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) {
                index += 1
                continue
            }

            let runtimeOnlyWidth = runtimeOnlyOptionWidth(arg)
            let width = runtimeOnlyWidth ?? optionWidth(args, index: index, policy: policy)
            if runtimeOnlyWidth != nil || shouldDropOption(arg, droppedOptions: policy.droppedOptions) {
                index += width
                continue
            }

            if policy.skipClaudeHookSettings,
               let replacement = claudeHookSettingsReplacement(args, index: index) {
                result.append(contentsOf: replacement)
                index += width
                continue
            }
            guard let consumedPromptBoundary = consumePromptBoundaryOption(arg, args: args, index: &index, width: width, policy: policy, result: &result) else { return nil }
            if consumedPromptBoundary { continue }
            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    /// Applies the Claude prompt trust boundary while preserving legacy positional behavior for every other policy.
    ///
    /// Direct Claude launches can resume options after prompt positionals because the CLI honors them. Claude Teams keeps
    /// its existing post-option prompt boundary so flag-shaped prompt payloads are not promoted during Teams restore.
    static func consumePositional(
        _ arg: String,
        policy: Policy,
        index: inout Int,
        result: inout [String],
        consumedFirstPositional: inout Bool,
        sawPositional: inout Bool,
        sawOptionBeforePositional: Bool,
        skippingResumePositionals: inout Bool
    ) -> Bool {
        if policy.scansOptionsPastPositionals {
            if !policy.promptBoundaryOptions.isEmpty, sawOptionBeforePositional {
                return true
            }
            if !sawPositional, policy.nonRestorableCommands.contains(arg) {
                return false
            }
            sawPositional = true
            index += 1
            return true
        }
        if policy.preservePositionals { result.append(arg); index += 1; return true }
        if let resumeSubcommand = policy.resumeSubcommand, arg == resumeSubcommand {
            skippingResumePositionals = true
            index += 1
            return true
        }
        if skippingResumePositionals {
            skippingResumePositionals = false
            index += 1
            return true
        }
        if policy.nonRestorableCommands.contains(arg) {
            return false
        }
        if policy.preserveFirstPositional, !consumedFirstPositional {
            result.append(arg)
            consumedFirstPositional = true
            index += 1
            return true
        }
        return true
    }

    static func shouldDropOption(_ arg: String, droppedOptions: Set<String>) -> Bool {
        if droppedOptions.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return droppedOptions.contains(String(arg[..<equals]))
    }

    static func optionWidth(
        _ args: [String],
        index: Int,
        policy: Policy,
        stopVariadicAtPositionals: Set<String> = []
    ) -> Int {
        let arg = args[index]
        if arg.contains("=") {
            return 1
        }
        if policy.optionalValueOptions.contains(arg) {
            guard index + 1 < args.count else { return 1 }
            let value = args[index + 1]
            if let choices = policy.optionalValueChoices[arg] { return choices.contains(value) ? 2 : 1 }
            let following = index + 2 < args.count ? args[index + 2] : nil
            if policy.greedyOptionalValueOptions.contains(arg),
               looksLikeGreedyOptionalValue(value) { return 2 }
            guard looksLikeOptionalValue(value, following: following) else { return 1 }
            return 2
        }
        guard policy.valueOptions.contains(arg) else {
            return unknownOptionWidth(args, index: index, policy: policy)
        }
        guard index + 1 < args.count else { return 1 }
        if policy.variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count,
                  !args[end].hasPrefix("-"),
                  !stopVariadicAtPositionals.contains(args[end]),
                  variadicValueCanContinue(args[end], policy: policy) {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    /// Infers one value for unknown direct-Claude options only when the value is bounded by another option or comma list.
    ///
    /// A trailing single word stays a prompt and is skipped. The deliberate trade-off is that a single-word prompt
    /// sandwiched between an unknown boolean flag and another flag can be treated as that unknown flag's value.
    static func unknownOptionWidth(_ args: [String], index: Int, policy: Policy) -> Int {
        guard policy.scansOptionsPastPositionals,
              policy.promptBoundaryOptions.isEmpty,
              index + 1 < args.count else { return 1 }
        let value = args[index + 1]
        let following = index + 2 < args.count ? args[index + 2] : nil
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.contains(",") || (following?.hasPrefix("-") == true) else {
            return 1
        }
        return 2
    }

    static func variadicValueCanContinue(_ value: String, policy: Policy) -> Bool {
        guard policy.scansOptionsPastPositionals else { return true }
        return looksLikeGreedyOptionalValue(value)
    }

    static func looksLikeOptionalValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return following == nil || value.contains(",") || (following?.hasPrefix("-") == true)
    }
}
