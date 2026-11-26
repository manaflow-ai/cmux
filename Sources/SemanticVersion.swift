import Foundation

struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func first(in output: String) -> SemanticVersion? {
        let pattern = #"(\d+)\.(\d+)(?:\.(\d+))?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range) else {
            return nil
        }

        func integer(at captureIndex: Int, fallback defaultValue: Int? = nil) -> Int? {
            let captureRange = match.range(at: captureIndex)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: output) else {
                return defaultValue
            }
            return Int(output[range])
        }

        guard let major = integer(at: 1),
              let minor = integer(at: 2) else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: integer(at: 3, fallback: 0) ?? 0)
    }
}
