import Foundation

/// The parsed absolute interpreter from an argument-free plugin shebang.
struct CmuxPluginShebang: Equatable, Sendable {
    /// Errors raised when a shebang is present but cannot be used safely.
    enum ParseError: Error, Sendable {
        case missingNewline
        case invalidArguments
    }

    /// The absolute interpreter path declared by the shebang.
    let interpreterPath: String
    /// Empty for supported shebangs; interpreter options are not admitted.
    let arguments: [String]

    /// Parses the first line of an executable, if it starts with `#!`.
    ///
    /// The prefix is intentionally bounded by the caller. A shebang without
    /// a newline in that bounded prefix is rejected rather than allowing an
    /// unbounded interpreter declaration to reach a process launch.
    /// Arguments are rejected because language-specific flags or positional
    /// paths can select code instead of the sealed entrypoint passed by cmux.
    ///
    /// - Parameter prefix: The first bytes of the executable.
    /// - Returns: A parsed shebang, or `nil` for a non-shebang executable.
    /// - Throws: ``ParseError`` for a malformed or unsafe shebang.
    static func parse(prefix: Data) throws -> Self? {
        let marker = Data("#!".utf8)
        guard prefix.starts(with: marker) else { return nil }
        guard let newline = prefix.firstIndex(of: 0x0A) else {
            throw ParseError.missingNewline
        }
        let line = String(decoding: prefix[marker.count..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let values = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let interpreterPath = values.first,
              interpreterPath.hasPrefix("/"),
              values.count == 1,
              values.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
              values.allSatisfy({
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw ParseError.invalidArguments
        }
        return Self(
            interpreterPath: interpreterPath,
            arguments: Array(values.dropFirst())
        )
    }
}
