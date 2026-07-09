import Foundation

extension CmuxVaultAgentRegistration {
    func processArgumentsCarryForkParentFlag(_ arguments: [String]) -> Bool {
        let markers = forkParentMarkerTokens()
        guard !markers.isEmpty else { return false }
        return markers.allSatisfy { marker in
            arguments.contains { argument in
                argument.compare(marker, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
    }

    private func forkParentMarkerTokens() -> [String] {
        guard let forkCommand else { return [] }
        let resumeConstants = Set(Self.constantTemplateTokens(in: resumeCommand))
        let forkConstants = Self.constantTemplateTokens(in: forkCommand)
        let markers = forkConstants.filter { !resumeConstants.contains($0) }
        // If fork and resume differ only by placeholders, the live argv carries no
        // constant marker that proves this process is a fork of its parent.
        return markers
    }

    private static func constantTemplateTokens(in template: String) -> [String] {
        splitShellWords(template).filter { !$0.contains("{{") && !$0.contains("}}") }
    }

    private static func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
        finishWord()
        return words
    }
}
