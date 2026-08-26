import Foundation

/// Stores one URL rule's bounded compiled representation.
struct BrowserExternalURLCompiledPattern: Sendable {
    private let maximumTargetLength = 16_384
    private let literalPattern: String?
    private let literalFallbackPattern: String?
    private let wildcardPattern: BrowserExternalURLWildcardPattern?
    private let regex: NSRegularExpression?

    init(literal: String) {
        literalPattern = literal
        literalFallbackPattern = nil
        wildcardPattern = nil
        regex = nil
    }

    init(regex: NSRegularExpression?) {
        literalPattern = nil
        literalFallbackPattern = nil
        wildcardPattern = nil
        self.regex = regex
    }

    init(literalFallback: String, regex: NSRegularExpression?) {
        literalPattern = nil
        literalFallbackPattern = literalFallback
        wildcardPattern = nil
        self.regex = regex
    }

    init(wildcard: BrowserExternalURLWildcardPattern) {
        literalPattern = nil
        literalFallbackPattern = nil
        wildcardPattern = wildcard
        regex = nil
    }

    init(unmatchable: Void = ()) {
        literalPattern = nil
        literalFallbackPattern = nil
        wildcardPattern = nil
        regex = nil
    }

    func matches(_ target: String) -> Bool {
        guard target.utf8.prefix(maximumTargetLength + 1).count <= maximumTargetLength else {
            return false
        }
        if let wildcardPattern {
            return wildcardPattern.matches(target)
        }
        if let literalPattern {
            return target.range(of: literalPattern, options: [.caseInsensitive]) != nil
        }
        if let literalFallbackPattern,
           target.range(of: literalFallbackPattern, options: [.caseInsensitive]) != nil {
            return true
        }
        guard let regex else { return false }
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return regex.firstMatch(in: target, options: [], range: range) != nil
    }
}
