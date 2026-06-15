import Foundation

/// Automatic ``SettingCodable/settingAllowedRawValues`` for enumerations.
///
/// Every cmux value enum is declared `CaseIterable & RawRepresentable` (almost
/// all with a `String` raw value, a few with `Int`). This constrained witness
/// derives the closed set of accepted raw values from `allCases`, so the
/// catalog exposes an enum's options — and the CLI validates membership and
/// `describe` lists them — with zero per-enum code. Add a new enum setting and
/// its cases surface in the CLI the moment the key is declared.
///
/// `RawValue: LosslessStringConvertible` covers both `String` (identity) and
/// `Int` (decimal) raw values; the witness renders each case's raw value as the
/// string a user types on the command line.
extension SettingCodable where Self: CaseIterable & RawRepresentable, Self.RawValue: LosslessStringConvertible {
    public static var settingAllowedRawValues: [String]? {
        allCases.map { String($0.rawValue) }
    }
}
