// The Linux shape of `String(localized:defaultValue:table:bundle:)`: swift-corelibs-foundation has no
// `String.LocalizationValue`, so the CmuxNext modules that build on Linux (scripts/ci/swift-linux-targets.txt)
// get this one, the same surface CMUXMobileCore ships for its Linux build. Darwin builds keep Foundation's.
#if !canImport(Darwin)
public import Foundation

extension String {
    /// The `String.LocalizationValue` surface this package and its dependents
    /// use, for Foundation builds without String Catalog lookup.
    public struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        public struct StringInterpolation: StringInterpolationProtocol, Sendable {
            var text: String
            let interpolationCount: Int

            public init(literalCapacity: Int, interpolationCount: Int) {
                text = ""
                text.reserveCapacity(literalCapacity)
                self.interpolationCount = interpolationCount
            }

            public mutating func appendLiteral(_ literal: String) {
                text += literal
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                text += String(describing: value)
            }
        }

        let text: String
        let hasArguments: Bool

        public init(stringLiteral value: String) {
            text = value
            hasArguments = false
        }

        public init(stringInterpolation: StringInterpolation) {
            text = stringInterpolation.text
            hasArguments = stringInterpolation.interpolationCount > 0
        }
    }

    /// Resolves a literal `defaultValue` through `bundle`'s compiled string
    /// tables; a value with interpolations is returned as rendered, since a
    /// table entry would need format arguments this type does not keep.
    public init(
        localized key: StaticString,
        defaultValue: LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale _: Locale = .current,
        comment _: StaticString? = nil
    ) {
        guard !defaultValue.hasArguments else {
            self = defaultValue.text
            return
        }
        self = (bundle ?? .main).localizedString(
            forKey: String(describing: key),
            value: defaultValue.text,
            table: table
        )
    }
}
#endif
