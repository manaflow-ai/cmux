import Foundation

/// Stores one URL rule's bounded compiled representation.
struct BrowserExternalURLCompiledPattern: Equatable, Sendable {
    private let maximumTargetLength = 16_384
    private let literalPattern: String?
    private let literalFallbackPattern: String?
    private let regex: NSRegularExpression?

    init(literal: String) {
        literalPattern = literal
        literalFallbackPattern = nil
        regex = nil
    }

    init(regex: NSRegularExpression?) {
        literalPattern = nil
        literalFallbackPattern = nil
        self.regex = regex
    }

    init(literalFallback: String, regex: NSRegularExpression?) {
        literalPattern = nil
        literalFallbackPattern = literalFallback
        self.regex = regex
    }

    init(unmatchable: Void = ()) {
        literalPattern = nil
        literalFallbackPattern = nil
        regex = nil
    }

    func matches(_ target: String) -> Bool {
        guard target.prefix(maximumTargetLength + 1).count <= maximumTargetLength else {
            return false
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
