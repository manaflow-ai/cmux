import Foundation

/// CLI-scoped counterpart of Foundation's initializer. Passing the bundle in
/// this one place also covers helpers compiled into the CLI from other files.
/// Keep the native key and LocalizationValue types: converting interpolation to
/// String before lookup would lose placeholder reordering and plural selection.
extension String {
    init(
        localized key: StaticString,
        defaultValue: String.LocalizationValue,
        table: String? = nil,
        locale: Locale = .current,
        comment: StaticString? = nil
    ) {
        self.init(
            localized: key,
            defaultValue: defaultValue,
            table: table,
            bundle: CMUXCLILocalization.bundle,
            locale: locale,
            comment: comment
        )
    }
}
