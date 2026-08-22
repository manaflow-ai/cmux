import Foundation

extension CMUXCLI {
    func unknownCommandError(_ command: String) -> CLIError {
        var message = "Unknown command '\(command)'."
        if let suggestion = suggestedCommandName(for: command) {
            message += " Did you mean '\(suggestion)'?"
        }
        message += " Run 'cmux --help' for the full command list."
        return CLIError(message: message, exitCode: 2)
    }

    private func suggestedCommandName(for command: String) -> String? {
        var bestName: String?
        var bestDistance = Int.max

        for candidate in Self.topLevelCommandNames where !candidate.hasPrefix("__") {
            let distance = editDistance(command, candidate)
            guard distance > 0, distance <= 2, distance < candidate.count else { continue }
            if distance < bestDistance || (distance == bestDistance && candidate < (bestName ?? candidate)) {
                bestName = candidate
                bestDistance = distance
            }
        }

        return bestName
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[rightIndex + 1] = previous[rightIndex]
                } else {
                    current[rightIndex + 1] = min(min(previous[rightIndex + 1], current[rightIndex]), previous[rightIndex]) + 1
                }
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    static var topLevelCommandNames: Set<String> {
        CmuxCommand.declaredCommandNames
    }
}
