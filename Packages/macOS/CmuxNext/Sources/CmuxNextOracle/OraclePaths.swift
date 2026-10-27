#if DEBUG || CMUX_BENCH_HOOKS
import CryptoKit
import Foundation

/// The run's nondeterministic path prefixes, the ones normalize.py's `Context` holds: the case root (`$ROOT`) and
/// the hermetic home (`$HOME`), several values per token for realpath aliases such as `/private/tmp`. The runner
/// passes them with each `debug.oracle.snapshot` (`paths`), because one app session runs several cases, each under
/// its own state root. A facet applies them only to a `derive: sha256` field with `x-oracle-rewrite: path`, which
/// normalize cannot rewrite after the hash (schemas/oracle/README.md, "Annotations").
public struct OraclePaths: Sendable, Hashable {
    /// No prefix: every text hashes as it is.
    public static let unchanged = OraclePaths(prefixes: [])

    private struct Prefix: Sendable, Hashable {
        var text: String
        var scalars: [Unicode.Scalar]
        var token: String
    }

    /// Longest first, as `_Rewriter` orders its alternation: a root inside the home is `$ROOT`.
    private let prefixes: [Prefix]

    private init(prefixes: [Prefix]) {
        self.prefixes = prefixes
    }

    /// Refuses what `_Rewriter` refuses: a prefix that is empty or `/`, and one prefix given for both tokens.
    public init(root: [String] = [], home: [String] = []) throws(OracleRequestError) {
        var table: [String: String] = [:]
        for (token, values) in [("$ROOT", root), ("$HOME", home)] {
            for value in values {
                var trimmed = value
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                guard !trimmed.isEmpty else { throw OracleRequestError.badPaths("\(token) prefix \"\(value)\" is empty or /") }
                if let other = table[trimmed], other != token {
                    throw OracleRequestError.badPaths("\"\(trimmed)\" is given for both \(other) and \(token)")
                }
                table[trimmed] = token
            }
        }
        let prefixes = table.map { Prefix(text: $0.key, scalars: Array($0.key.unicodeScalars), token: $0.value) }
        self.init(prefixes: prefixes.sorted { a, b in
            a.scalars.count != b.scalars.count ? a.scalars.count > b.scalars.count : a.text < b.text
        })
    }

    /// `text` with each whole-path occurrence of a prefix written as its token, as normalize.py's `_Rewriter`
    /// rewrites `path` fields: scanned left to right, at each place the longest prefix that is not inside a longer
    /// name (`/tmp/o/ab` in `/tmp/o/abc`) wins.
    public func rewrite(_ text: String) -> String {
        guard !prefixes.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if index == 0 || !Self.isNameScalar(scalars[index - 1]), let prefix = match(scalars, at: index) {
                result.append(contentsOf: prefix.token.unicodeScalars)
                index += prefix.scalars.count
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    /// `sha256:<hex>` of `text` after ``rewrite(_:)``: the capture's order for a `derive: sha256` field with
    /// `x-oracle-rewrite: path`.
    public func hash(_ text: String) -> String {
        OracleValue.sha256(rewrite(text))
    }

    private func match(_ scalars: [Unicode.Scalar], at index: Int) -> Prefix? {
        prefixes.first { prefix in
            let end = index + prefix.scalars.count
            guard end <= scalars.count, scalars[index..<end].elementsEqual(prefix.scalars) else { return false }
            return end == scalars.count || !Self.isNameScalar(scalars[end])
        }
    }

    /// normalize.py's path-name class, `[A-Za-z0-9._~-]`.
    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "~", "-": true
        default: false
        }
    }
}

extension OracleValue {
    /// `sha256:<hex>` of `text`'s UTF-8 bytes, the schema's `derive: sha256`: private text never goes in. A field
    /// with `x-oracle-rewrite: path` hashes through ``OraclePaths/hash(_:)`` instead.
    public static func sha256(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
