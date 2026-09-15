import Foundation

public struct CodexWriterLegacyResume: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: String]

    init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }
}

extension CodexWriterRecovery {
    public static func codexLegacyResume(
        inShellCommand command: String,
        environment: [String: String]
    ) -> CodexWriterLegacyResume? {
        codexLegacyResume(inShellCommand: command, environment: environment, depth: 0)
    }

    private static func codexLegacyResume(
        inShellCommand command: String,
        environment: [String: String],
        depth: Int
    ) -> CodexWriterLegacyResume? {
        guard depth < 4 else { return nil }
        let normalized = command.replacingOccurrences(
            of: AgentResumeArgv.codexWrapperShellExecutableToken,
            with: "codex"
        )
        return shellCommandSegments(normalized).compactMap {
            codexLegacyResume(in: $0, environment: environment, depth: depth)
        }.first
    }

    private static func codexLegacyResume(
        in segment: [String],
        environment: [String: String],
        depth: Int
    ) -> CodexWriterLegacyResume? {
        var effectiveEnvironment = environment
        var executableIndex = 0
        while executableIndex < segment.count,
              isEnvironmentAssignment(segment[executableIndex]) {
            applyEnvironmentAssignment(segment[executableIndex], to: &effectiveEnvironment)
            executableIndex += 1
        }
        if executableIndex < segment.count,
           segment[executableIndex] == "env" || segment[executableIndex] == "/usr/bin/env" {
            executableIndex += 1
            while executableIndex < segment.count,
                  isEnvironmentAssignment(segment[executableIndex]) {
                applyEnvironmentAssignment(segment[executableIndex], to: &effectiveEnvironment)
                executableIndex += 1
            }
        }
        guard executableIndex < segment.count else { return nil }
        let arguments = Array(segment[executableIndex...])
        guard let executable = arguments.first else { return nil }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        if ["sh", "bash", "zsh"].contains(executableName),
           arguments.count >= 3,
           arguments[1] == "-c" || arguments[1] == "-lc" {
            return codexLegacyResume(
                inShellCommand: arguments[2],
                environment: effectiveEnvironment,
                depth: depth + 1
            )
        }
        guard codexResumeSessionID(arguments: arguments) != nil else { return nil }
        return CodexWriterLegacyResume(arguments: arguments, environment: effectiveEnvironment)
    }

    private static func shellCommandSegments(_ command: String) -> [[String]] {
        var segments: [[String]] = [[]]
        var currentWord = ""
        var hasCurrentWord = false
        var quote: Character?
        var index = command.startIndex

        func finishWord() {
            guard hasCurrentWord else { return }
            segments[segments.count - 1].append(currentWord)
            currentWord = ""
            hasCurrentWord = false
        }

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"" && character == "\\" {
                    let nextIndex = command.index(after: index)
                    if nextIndex < command.endIndex,
                       ["$", "`", "\"", "\\", "\n"].contains(command[nextIndex]) {
                        currentWord.append(command[nextIndex])
                        hasCurrentWord = true
                        index = command.index(after: nextIndex)
                        continue
                    }
                    currentWord.append(character)
                } else {
                    currentWord.append(character)
                    hasCurrentWord = true
                }
            } else {
                switch character {
                case "'", "\"":
                    quote = character
                    hasCurrentWord = true
                case "\\":
                    let nextIndex = command.index(after: index)
                    if nextIndex < command.endIndex {
                        currentWord.append(command[nextIndex])
                        hasCurrentWord = true
                        index = command.index(after: nextIndex)
                        continue
                    } else {
                        currentWord.append(character)
                        hasCurrentWord = true
                    }
                case " ", "\t", "\n":
                    finishWord()
                case ";":
                    finishWord()
                    segments.append([])
                case "&", "|":
                    finishWord()
                    let nextIndex = command.index(after: index)
                    if nextIndex < command.endIndex, command[nextIndex] == character {
                        index = nextIndex
                    }
                    segments.append([])
                default:
                    currentWord.append(character)
                    hasCurrentWord = true
                }
            }
            index = command.index(after: index)
        }
        guard quote == nil else { return [] }
        finishWord()
        return segments.filter { !$0.isEmpty }
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalsIndex = value.firstIndex(of: "="), equalsIndex != value.startIndex else {
            return false
        }
        let name = value[..<equalsIndex]
        guard let firstScalar = name.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
                  .contains(firstScalar) else {
            return false
        }
        let allowedScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"
        )
        return name.unicodeScalars.allSatisfy(allowedScalars.contains)
    }

    private static func applyEnvironmentAssignment(
        _ assignment: String,
        to environment: inout [String: String]
    ) {
        guard let equalsIndex = assignment.firstIndex(of: "=") else { return }
        let name = String(assignment[..<equalsIndex])
        let value = String(assignment[assignment.index(after: equalsIndex)...])
        environment[name] = value
    }
}
