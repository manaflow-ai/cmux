import Foundation

/// One process matcher with its path expressions compiled for the lifetime of
/// the accepted catalog generation.
struct CmuxAgentCompiledProcessMatcher: Sendable {
    private enum ArgumentJoinMode: Sendable {
        case spaces
        case isolated
    }

    private struct ArgumentCondition: Sendable {
        let mode: ArgumentJoinMode
        let literal: String
    }

    let matcher: CmuxAgentProcessMatcher
    private let normalizedPathContains: [String]
    private let processPathRegex: [CmuxAgentCompiledRegex]
    private let argvContainsAll: [ArgumentCondition]
    private let argvContainsAny: [ArgumentCondition]
    private let argvBasenamesAny: Set<String>

    init(
        matcher: CmuxAgentProcessMatcher,
        reportsRegexProgress: Bool
    ) {
        self.matcher = matcher
        self.normalizedPathContains = matcher.processPathContains.map {
            $0.replacingOccurrences(of: "\\", with: "/")
        }
        self.processPathRegex = matcher.processPathRegex.compactMap {
            CmuxAgentCompiledRegex(
                $0,
                reportsProgress: reportsRegexProgress
            )
        }
        self.argvContainsAll = Self.compileArgumentConditions(matcher.argvContainsAll)
        self.argvContainsAny = Self.compileArgumentConditions(matcher.argvContainsAny)
        self.argvBasenamesAny = Set(matcher.argvBasenamesAny.map { $0.lowercased() })
    }

    func matches(
        _ context: CmuxAgentProcessEvaluationContext,
        evaluation: inout CmuxAgentProcessEvaluationState
    ) -> CmuxAgentRuleEvaluationOutcome {
        let process = context.process
        var namesMatch = matcher.processNames.isEmpty
        for expected in matcher.processNames {
            guard evaluation.workBudget.consume(
                bytes: context.executableBasenamesByteCount
            ) else {
                return .budgetExceeded
            }
            if context.executableBasenames.contains(where: {
                $0.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }) {
                namesMatch = true
                break
            }
        }
        guard namesMatch else { return .notMatched }

        if !matcher.processPathContains.isEmpty {
            guard let normalizedPath = context.normalizedProcessPath else {
                return .notMatched
            }
            guard normalizedPathContains.count == matcher.processPathContains.count else {
                return .notMatched
            }
            for needle in normalizedPathContains {
                guard evaluation.workBudget.consume(bytes: context.processPathByteCount) else {
                    return .budgetExceeded
                }
                guard normalizedPath.range(
                    of: needle,
                    options: [.caseInsensitive, .literal]
                ) != nil else {
                    return .notMatched
                }
            }
        }

        if !matcher.processPathRegex.isEmpty {
            guard let processPath = process.processPath,
                  processPathRegex.count == matcher.processPathRegex.count else {
                return .notMatched
            }
            let range = NSRange(processPath.startIndex..<processPath.endIndex, in: processPath)
            var didMatch = false
            for regex in processPathRegex {
                guard evaluation.workBudget.consume(bytes: context.processPathByteCount) else {
                    return .budgetExceeded
                }
                let deadline = evaluation.regexDeadline ?? CmuxAgentEvaluationDeadline()
                evaluation.regexDeadline = deadline
                switch regex.firstMatch(in: processPath, range: range, deadline: deadline) {
                case .matched:
                    didMatch = true
                case .notMatched:
                    break
                case .budgetExceeded:
                    return .budgetExceeded
                }
                if didMatch { break }
            }
            guard didMatch else { return .notMatched }
        }

        guard argvContainsAll.count == matcher.argvContainsAll.count,
              argvContainsAny.count == matcher.argvContainsAny.count else {
            return .notMatched
        }
        for condition in argvContainsAll {
            switch argumentConditionMatches(
                condition,
                context: context,
                evaluation: &evaluation
            ) {
            case .matched:
                break
            case .notMatched:
                return .notMatched
            case .budgetExceeded:
                return .budgetExceeded
            }
        }
        if !argvContainsAny.isEmpty {
            var found = false
            for condition in argvContainsAny {
                switch argumentConditionMatches(
                    condition,
                    context: context,
                    evaluation: &evaluation
                ) {
                case .matched:
                    found = true
                case .notMatched:
                    continue
                case .budgetExceeded:
                    return .budgetExceeded
                }
                break
            }
            guard found else { return .notMatched }
        }
        if !argvBasenamesAny.isEmpty {
            guard evaluation.workBudget.consume(bytes: context.argumentsByteCount) else {
                return .budgetExceeded
            }
            guard basenameEntrypointMatches(context) else {
                return .notMatched
            }
        }
        for (key, expected) in matcher.environmentEquals {
            let comparedBytes = key.utf8.count
                + expected.utf8.count
                + (process.environment[key]?.utf8.count ?? 0)
            guard evaluation.workBudget.consume(bytes: comparedBytes) else {
                return .budgetExceeded
            }
            guard process.environment[key] == expected else { return .notMatched }
        }
        return .matched
    }

    private static func compileArgumentConditions(
        _ needles: [String]
    ) -> [ArgumentCondition] {
        needles.compactMap { needle in
            guard !needle.isEmpty else {
                return nil
            }
            return ArgumentCondition(
                mode: needle.contains(" ") ? .spaces : .isolated,
                literal: needle
            )
        }
    }

    private func argumentConditionMatches(
        _ condition: ArgumentCondition,
        context: CmuxAgentProcessEvaluationContext,
        evaluation: inout CmuxAgentProcessEvaluationState
    ) -> CmuxAgentRuleEvaluationOutcome {
        let arguments = context.process.arguments
        let candidate: String
        switch condition.mode {
        case .spaces:
            candidate = evaluation.argumentsJoinedWithSpaces(arguments)
        case .isolated:
            candidate = evaluation.argumentsKeptSeparate(arguments)
        }
        guard evaluation.workBudget.consume(bytes: max(candidate.utf8.count, 1)) else {
            return .budgetExceeded
        }
        let matched = (candidate as NSString).range(
            of: condition.literal,
            options: [.caseInsensitive, .literal]
        ).location != NSNotFound
        return matched ? .matched : .notMatched
    }

    private func basenameEntrypointMatches(
        _ context: CmuxAgentProcessEvaluationContext
    ) -> Bool {
        let arguments = context.process.arguments
        guard !arguments.isEmpty else { return false }
        if context.executableBasenames.contains(where: Self.isPythonRuntimeBasename) {
            guard let index = pythonEntrypointIndex(arguments) else { return false }
            return argvBasenamesAny.contains(
                (arguments[index] as NSString).lastPathComponent.lowercased()
            )
        }
        return arguments.contains {
            argvBasenamesAny.contains(($0 as NSString).lastPathComponent.lowercased())
        }
    }

    private func pythonEntrypointIndex(_ arguments: [String]) -> Int? {
        var index = 0
        if index < arguments.count,
           Self.isPythonRuntimeBasename(
               (arguments[index] as NSString).lastPathComponent
           ) {
            index += 1
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? index + 1 : nil }
            if argument == "-" { return nil }
            if argument == "-m" { return index + 1 < arguments.count ? index + 1 : nil }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init)
                ?? argument
            if ["-c", "-h", "--help", "-V", "--version"].contains(option) {
                return nil
            }
            if argument.hasPrefix("-") {
                index += 1 + Self.pythonOptionValueCount(argument)
                continue
            }
            return index
        }
        return nil
    }

    private static func isPythonRuntimeBasename(_ value: String) -> Bool {
        let basename = value.lowercased()
        if basename == "python" || basename == "python3" {
            return true
        }
        guard basename.hasPrefix("python3.") else { return false }
        let suffix = basename.dropFirst("python3.".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func pythonOptionValueCount(_ argument: String) -> Int {
        guard !argument.contains("=") else { return 0 }
        if ["-W", "-X", "--check-hash-based-pycs"].contains(argument) {
            return 1
        }
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"),
              let last = argument.last else {
            return 0
        }
        return last == "W" || last == "X" ? 1 : 0
    }
}
