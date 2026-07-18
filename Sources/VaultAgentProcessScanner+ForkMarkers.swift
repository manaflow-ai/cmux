import Foundation

extension CmuxVaultAgentRegistration {
    func processArgumentsCarryForkParentFlag(_ arguments: [String]) -> Bool {
        let markers = forkParentMarkerTokens()
        guard !markers.isEmpty else { return false }
        return markers.allSatisfy { marker in
            arguments.contains { argument in
                argument.compare(marker.token, options: [.caseInsensitive, .literal]) == .orderedSame
                    || (marker.acceptsAttachedValue && argument.range(
                        of: marker.token + "=",
                        options: [.anchored, .caseInsensitive, .literal]
                    ) != nil)
            }
        }
    }

    private func forkParentMarkerTokens() -> [(token: String, acceptsAttachedValue: Bool)] {
        guard let forkCommand else { return [] }
        let resumeConstants = Set(Self.constantTemplateTokens(in: resumeCommand))
        let forkTokens = Self.splitShellWords(forkCommand)
        let markers = forkTokens.enumerated().compactMap { index, token -> (String, Bool)? in
            guard !token.contains("{{"), !token.contains("}}"), !resumeConstants.contains(token) else {
                return nil
            }
            let nextIndex = forkTokens.index(after: index)
            let acceptsAttachedValue = token.hasPrefix("-")
                && nextIndex < forkTokens.endIndex
                && Self.isSessionPlaceholder(forkTokens[nextIndex])
            return (token, acceptsAttachedValue)
        }
        // If fork and resume differ only by placeholders, the live argv carries no
        // constant marker that proves this process is a fork of its parent.
        return markers
    }

    private static func isSessionPlaceholder(_ token: String) -> Bool {
        token.contains("{{sessionId}}") || token.contains("{{sessionPath}}")
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
