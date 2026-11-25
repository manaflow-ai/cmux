public import Foundation

// What the settings model reads from Apple frameworks, for the Linux build (CmuxNextSettings there is a scratch
// package of Sources/CmuxNextSettings files listed in sources.txt). Text is the English source, which the
// exports use; the app resolves the localized strings from the xcstrings on the Mac.
#if !canImport(AppKit)
extension String {
    public struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        public let value: String
        public init(stringLiteral value: String) { self.value = value }
        public init(stringInterpolation: DefaultStringInterpolation) { self.value = String(stringInterpolation: stringInterpolation) }
    }
    public init(localized key: StaticString, defaultValue: String.LocalizationValue, table: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) { self = defaultValue.value }
}

public nonisolated struct ModuleResourceBundle: Sendable {
    public func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String { defaultValue.value }
    nonisolated static let settings = ModuleResourceBundle()
}
#endif
