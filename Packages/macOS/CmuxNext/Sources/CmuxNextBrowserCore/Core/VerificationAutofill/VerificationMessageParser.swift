package import Foundation

/// Reads a verification email's codes, origin-bound line and https links
/// (plans/cmux-next/email-verification-autofill/DESIGN.md). It reports what
/// it finds; ``VerificationOfferPolicy`` decides what a page gets.
///
/// A code is a number of 4 to 8 digits (`123456`, `123 456`, `123-456`) or
/// 6 to 8 capital letters and digits with at least one of each (`K7QX2M`),
/// on a line with a code word ("code", "verification", "OTP", "PIN", ...) or
/// right after one. Years, prices, order numbers (`#123`), parts of links
/// and phone-number groups are not codes.
public nonisolated struct VerificationMessageParser: Sendable {
    public init() {}

    /// Parses one email in memory; nothing is kept.
    /// - Parameter email: The email.
    /// - Returns: Its codes, origin-bound code and safe links.
    public func parse(_ email: VerificationEmail) -> VerificationMessage {
        var message = VerificationMessage()
        let bodyLines = email.body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        message.originBoundCode = bodyLines.last.flatMap(Self.originBoundCode)

        var codes: [String] = []
        func collect(_ line: String) {
            for code in Self.codes(in: line) where !codes.contains(code) { codes.append(code) }
        }
        if Self.hasCodeWord(email.subject) { collect(email.subject) }
        var previousHasCodeWord = false
        for line in bodyLines {
            let hasCodeWord = Self.hasCodeWord(line)
            if hasCodeWord || previousHasCodeWord { collect(line) }
            previousHasCodeWord = hasCodeWord
        }
        message.codes = codes
        message.links = Self.safeLinks(email.links + Self.links(in: email.body))
        return message
    }

    // MARK: - Codes

    // The patterns are constants that VerificationMessageParserTests exercise; were one ever to
    // fail to compile, the parser finds nothing rather than crash.

    /// A code word, in English and the most common other languages. Words
    /// that put a number next to "code" without it being one are excluded.
    private static let codeWord = try? NSRegularExpression(
        pattern: #"(code|c[oó]digo|verif|vérif|bestätigung|one-time|\botp\b|passcode|\bpin\b|\b2fa\b|コード|認証|验证码|驗證碼|인증|код)"#,
        options: [.caseInsensitive]
    )
    private static let notACodeWord = try? NSRegularExpression(
        pattern: #"\b(zip|postal|post|promo|discount|coupon|gift|area|country|tracking|source|qr|bar)\s?code"#,
        options: [.caseInsensitive]
    )

    private static func hasCodeWord(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        guard let codeWord, let notACodeWord, codeWord.firstMatch(in: line, range: range) != nil else { return false }
        // A line whose only code words are excluded ones ("zip code 94107") has none.
        let all = codeWord.numberOfMatches(in: line, range: range)
        let excluded = notACodeWord.numberOfMatches(in: line, range: range)
        return all > excluded
    }

    /// A candidate code: not glued to letters, digits, `#`, `$`, link or
    /// decimal punctuation, and not one group of a longer digit run.
    private static let candidate = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9#$€£¥=/._?&@:+-])(?<![0-9] )([0-9]{3}[ -][0-9]{3}|[0-9]{4,8}|(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8})(?![A-Za-z0-9_/=%+-]|[.,][0-9]| [0-9])"#
    )

    private static func codes(in line: String) -> [String] {
        guard let candidate else { return [] }
        return candidate.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            let code = String(line[range].filter { $0 != " " && $0 != "-" })
            return isYear(code) ? nil : code
        }
    }

    private static func isYear(_ code: String) -> Bool {
        guard code.count == 4, let value = Int(code) else { return false }
        return (1900...2099).contains(value)
    }

    // MARK: - Origin-bound codes

    /// `@example.com #123456` alone on the last line. The embedded form
    /// (`@top #code @frame`) has more after the code and does not match.
    private static let originBound = try? NSRegularExpression(pattern: #"^@([A-Za-z0-9.-]+) #([A-Za-z0-9]{4,12})$"#)

    private static func originBoundCode(_ line: String) -> OriginBoundCode? {
        guard let match = originBound?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hostRange = Range(match.range(at: 1), in: line), let codeRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return OriginBoundCode(host: String(line[hostRange]).lowercased(), code: String(line[codeRange]))
    }

    // MARK: - Links

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }

    /// https only, a host, no user info, the default port; each link once.
    private static func safeLinks(_ links: [URL]) -> [URL] {
        var seen = Set<String>()
        return links.filter { url in
            guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443
            else { return false }
            return seen.insert(url.absoluteString).inserted
        }
    }
}
