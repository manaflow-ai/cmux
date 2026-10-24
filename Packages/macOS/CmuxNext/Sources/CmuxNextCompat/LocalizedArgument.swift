public import Foundation

/// One value that ``Foundation/Bundle/localizedString(forKey:value:table:arguments:preferredLocalizations:locale:)``
/// writes into a localized sentence.
///
/// A ``count(_:)`` fills an integer specifier (`%lld`) and picks the catalog's plural variation, so the
/// noun after it agrees with the number in every language. Every other case fills a `%@` with text that
/// Foundation writes in the sentence's language (CLDR units), so no translation writes a unit after a
/// number: a fixed unit or noun after a number cannot agree with every count in Arabic or the Slavic
/// languages, and a later translation pass cannot bring one back.
///
/// ```swift
/// Bundle.module.localizedString(
///     forKey: "rd.state.latency.detail",
///     value: "%1$@, %2$@. Control turns off above %3$@.", table: nil,
///     arguments: [.duration(.milliseconds(rtt), units: [.milliseconds]), .text(path),
///                 .duration(.milliseconds(limit), units: [.milliseconds])],
///     preferredLocalizations: Bundle.module.preferredLocalizations)
/// ```
public enum LocalizedArgument: Sendable {
    /// A count for an integer specifier (`%lld`, `%ld` or `%d`); the catalog's plural variation agrees with it.
    case count(Int)
    /// A duration for a `%@`, written in CLDR's abbreviated units of the sentence's language ("5 min", ar "5 د").
    ///
    /// `units` are the units the duration may be written in: `[.minutes]` writes whole minutes,
    /// `[.milliseconds]` whole milliseconds.
    case duration(Duration, units: Set<Duration.UnitsFormatStyle.Unit>)
    /// A number of bytes for a `%@`, written exactly with CLDR's byte unit ("1 byte", "4,096 bytes", pl "2 bajty").
    case byteCount(Int64)
    /// Text for a `%@`, written as is (a name, a path, or a phrase that is already localized).
    case text(String)

    /// Whether this argument fills an integer specifier (true) or a `%@` (false).
    var isCount: Bool {
        if case .count = self { return true }
        return false
    }

    /// The value `String(format:locale:arguments:)` receives for this argument; units are written in `locale`.
    func formatArgument(in locale: Locale) -> any CVarArg {
        switch self {
        case .count(let count):
            count
        case .duration(let duration, let units):
            duration.formatted(.units(allowed: units, width: .abbreviated).locale(locale))
        case .byteCount(let bytes):
            bytes.formatted(.byteCount(style: .file, allowedUnits: .bytes, spellsOutZero: false).locale(locale))
        case .text(let text):
            text
        }
    }
}
