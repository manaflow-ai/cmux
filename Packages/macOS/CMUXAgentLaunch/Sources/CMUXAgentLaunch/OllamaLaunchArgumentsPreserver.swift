import Foundation

/// Preserves only the interactive Ollama launch shape that can be safely relaunched.
struct OllamaLaunchArgumentsPreserver {
    private static let valueOptions: Set<String> = [
        "--dimensions",
        "--format",
        "--height",
        "--keepalive",
        "--negative",
        "--seed",
        "--steps",
        "--width",
    ]

    private static let flagOptions: Set<String> = [
        "--experimental",
        "--experimental-websearch",
        "--experimental-yolo",
        "--hidethinking",
        "--insecure",
        "--nowordwrap",
        "--truncate",
        "--verbose",
    ]

    private static let thinkingLevels: Set<String> = [
        "false", "high", "low", "medium", "true",
    ]

    func preservedArguments(_ arguments: [String]) -> [String]? {
        guard arguments.first == "run" else { return nil }

        var result = ["run"]
        var model: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" || argument == "-h" || argument == "--help" {
                return nil
            }
            if argument.hasPrefix("-") {
                guard preserveOption(
                    argument,
                    arguments: arguments,
                    index: &index,
                    result: &result
                ) else {
                    return nil
                }
                continue
            }
            if model == nil {
                model = argument
                result.append(argument)
                index += 1
                continue
            }

            // A second positional is Ollama's one-shot prompt. Relaunching it
            // would repeat user work and may exit instead of opening the REPL.
            break
        }

        guard model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return result
    }

    private func preserveOption(
        _ argument: String,
        arguments: [String],
        index: inout Int,
        result: inout [String]
    ) -> Bool {
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        if option == "--think" {
            guard !argument.hasSuffix("=") else { return false }
            result.append(argument)
            if !argument.contains("="),
               index + 1 < arguments.count,
               Self.thinkingLevels.contains(arguments[index + 1].lowercased()) {
                result.append(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
            return true
        }
        if Self.flagOptions.contains(option) {
            result.append(argument)
            index += 1
            return true
        }
        guard Self.valueOptions.contains(option) else { return false }
        if argument.contains("=") {
            let value = argument.dropFirst(option.count + 1)
            guard !value.isEmpty else { return false }
            result.append(argument)
            index += 1
            return true
        }
        guard index + 1 < arguments.count else { return false }
        result.append(argument)
        result.append(arguments[index + 1])
        index += 2
        return true
    }
}
