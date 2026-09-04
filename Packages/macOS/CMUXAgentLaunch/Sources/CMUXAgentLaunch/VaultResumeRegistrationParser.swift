import Foundation

/// The result of normalizing a registration's leading environment prefix.
struct VaultResumeParsedRegistration: Equatable, Sendable {
    let registration: VaultResumeLaunchRequest.Registration
    let environment: [String: String]
    let isSupported: Bool
}

/// Extracts replay-safe environment assignments from a Vault registration.
struct VaultResumeRegistrationParser: Sendable {
    /// Parses a registration, retaining the original command when no leading
    /// `env` prefix is present.
    func parse(
        _ registration: VaultResumeLaunchRequest.Registration
    ) -> VaultResumeParsedRegistration {
        let words = shellWordRanges(registration.resumeCommand)
        guard let commandStartIndex = leadingRegistrationCommandIndex(in: words) else {
            return unsupportedRegistration(registration)
        }
        guard words.indices.contains(commandStartIndex) else {
            return VaultResumeParsedRegistration(
                registration: registration,
                environment: [:],
                isSupported: true
            )
        }
        let executable = words[commandStartIndex].value
        guard (executable as NSString).lastPathComponent == "env" else {
            return VaultResumeParsedRegistration(
                registration: registration,
                environment: [:],
                isSupported: true
            )
        }

        let policy = AgentLaunchEnvironmentPolicy()
        var environment: [String: String] = [:]
        var index = commandStartIndex + 1
        while index < words.count {
            let token = words[index].value
            guard let equals = token.firstIndex(of: "=") else { break }
            let key = String(token[..<equals])
            let renderedValue = String(token[token.index(after: equals)...])
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  let value = decodedEnvironmentAssignmentValue(renderedValue),
                  value.unicodeScalars.allSatisfy(isSafeEnvironmentScalar),
                  let replayValue = policy.registrationEnvironmentValue(key: key, value: value) else {
                return VaultResumeParsedRegistration(
                    registration: registration,
                    environment: [:],
                    isSupported: false
                )
            }
            // The policy supplies the allow-list and NODE_OPTIONS sanitizer.
            // Registration-owned paths (especially CLAUDE_CONFIG_DIR) must
            // otherwise remain byte-for-byte identical to the user's value.
            environment[key] = replayValue
            index += 1
        }

        guard !environment.isEmpty,
              index < words.count,
              !words[index].value.hasPrefix("-") else {
            return VaultResumeParsedRegistration(
                registration: registration,
                environment: [:],
                isSupported: false
            )
        }

        var normalized = registration
        normalized.resumeCommand = String(
            registration.resumeCommand[words[index].range.lowerBound...]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.resumeCommand.isEmpty else {
            return VaultResumeParsedRegistration(
                registration: registration,
                environment: [:],
                isSupported: false
            )
        }
        return VaultResumeParsedRegistration(
            registration: normalized,
            environment: environment,
            isSupported: true
        )
    }

    private struct ShellWordRange: Sendable {
        let value: String
        let range: Range<String.Index>
    }

    /// Finds an `env` token after the generated leading cwd guard.
    private func leadingRegistrationCommandIndex(
        in words: [ShellWordRange]
    ) -> Int? {
        guard let first = words.first?.value,
              first == "cd" || first == "{" else {
            return 0
        }
        for index in words.indices where index > words.startIndex {
            guard words[index - 1].value == "&&" else { continue }
            let candidate = words[index].value
            return (candidate as NSString).lastPathComponent == "env" ? index : nil
        }
        return nil
    }

    /// Returns a fail-closed result for a cwd guard that cannot be normalized.
    private func unsupportedRegistration(
        _ registration: VaultResumeLaunchRequest.Registration
    ) -> VaultResumeParsedRegistration {
        VaultResumeParsedRegistration(
            registration: registration,
            environment: [:],
            isSupported: false
        )
    }

    /// Decodes the ASCII-octal command-substitution form used for Unicode values.
    private func decodedEnvironmentAssignmentValue(_ value: String) -> String? {
        let prefix = "$(printf '"
        let suffix = "')"
        guard value.contains("$") || value.contains("`") else { return value }
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
        let encoded = value.dropFirst(prefix.count).dropLast(suffix.count)
        guard encoded.first == "\\" else { return nil }
        let octets = encoded.split(separator: "\\", omittingEmptySubsequences: true)
        guard !octets.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(octets.count)
        for octet in octets {
            guard octet.count == 3,
                  let byte = UInt8(String(octet), radix: 8) else {
                return nil
            }
            bytes.append(byte)
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    /// Returns whether a captured environment scalar is safe to replay.
    private func isSafeEnvironmentScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }

    /// Tokenizes the small POSIX subset needed to inspect a registration prefix.
    private func shellWordRanges(_ command: String) -> [ShellWordRange] {
        enum Quote {
            case single
            case double
        }

        var words: [ShellWordRange] = []
        var current = ""
        var wordStart: String.Index?
        var quote: Quote?
        var hasCurrentWord = false
        let doubleQuoteEscapable: Set<Character> = ["$", "`", "\"", "\\", "\n"]

        func markWordStart(_ index: String.Index) {
            if wordStart == nil {
                wordStart = index
            }
            hasCurrentWord = true
        }

        func finishWord(at end: String.Index) {
            guard hasCurrentWord else { return }
            words.append(ShellWordRange(value: current, range: (wordStart ?? end)..<end))
            current = ""
            wordStart = nil
            hasCurrentWord = false
        }

        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                markWordStart(index)
                quote = .single
            case (nil, "\""):
                markWordStart(index)
                quote = .double
            case (.double, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex,
                   doubleQuoteEscapable.contains(command[next]) {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord(at: index)
            default:
                markWordStart(index)
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishWord(at: command.endIndex)
        return words
    }
}
