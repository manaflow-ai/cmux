import Foundation

/// Resolves profile aliases created by Hermes's `profile alias` command.
struct HermesProfileAliasResolver {
    struct Alias: Equatable, Sendable {
        let commandName: String
        let wrapperPath: String
    }

    private let wrapperDirectoryURL: URL
    private let fileManager: FileManager
    /// Hermes-generated wrappers are two lines; reject unexpectedly large files after a bounded read.
    private let maximumWrapperByteCount = 2_048

    init(wrapperDirectoryURL: URL, fileManager: FileManager) {
        self.wrapperDirectoryURL = wrapperDirectoryURL
        self.fileManager = fileManager
    }

    func resolve(excluding reservedCommandNames: Set<String>) -> [Alias] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: wrapperDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            alias(at: entry, excluding: reservedCommandNames)
        }.sorted { lhs, rhs in
            lhs.commandName < rhs.commandName
        }
    }

    private func alias(at url: URL, excluding reservedCommandNames: Set<String>) -> Alias? {
        let commandName = url.lastPathComponent
        guard Self.isValidIdentifier(commandName),
              !reservedCommandNames.contains(commandName),
              fileManager.isExecutableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let contents = boundedContents(of: url),
              Self.officialProfileName(in: contents) != nil else {
            return nil
        }
        return Alias(
            commandName: commandName,
            wrapperPath: url.standardizedFileURL.path
        )
    }

    private func boundedContents(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumWrapperByteCount + 1),
              data.count <= maximumWrapperByteCount else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func officialProfileName(in contents: String) -> String? {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.count == 2,
              lines[0] == "#!/bin/sh",
              lines[1].hasPrefix("exec "),
              lines[1].hasSuffix(" \"$@\"") else {
            return nil
        }

        let argumentSuffix = " \"$@\""
        let commandStart = lines[1].index(lines[1].startIndex, offsetBy: "exec ".count)
        let commandEnd = lines[1].index(lines[1].endIndex, offsetBy: -argumentSuffix.count)
        let command = String(lines[1][commandStart..<commandEnd])
        guard let profileFlag = command.range(of: " -p ", options: .backwards) else { return nil }

        let executable = String(command[..<profileFlag.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let profileName = String(command[profileFlag.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard isHermesExecutable(executable), isValidIdentifier(profileName) else { return nil }
        return profileName
    }

    private static func isHermesExecutable(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.contains(where: { $0.isWhitespace }),
           !(token.hasPrefix("'") && token.hasSuffix("'")) {
            return false
        }
        let finalComponent = token.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? token
        return finalComponent.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) == "hermes"
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count), let first = scalars.first,
              Self.isLowercaseASCII(first) || Self.isASCIIDigit(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { scalar in
            Self.isLowercaseASCII(scalar)
                || Self.isASCIIDigit(scalar)
                || scalar == "_"
                || scalar == "-"
        }
    }

    private static func isLowercaseASCII(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}
