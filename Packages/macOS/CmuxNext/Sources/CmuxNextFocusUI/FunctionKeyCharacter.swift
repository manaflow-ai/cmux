import Foundation

/// The key-equivalent character of an AppKit function key (`NSPageUpFunctionKey`
/// and the others are Unicode private-use scalars, U+F700 and up). Never traps:
/// a code that is not a scalar gives "" (FunctionKeyCharacterTests checks
/// every code the app uses).
public nonisolated struct FunctionKeyCharacter {
    public nonisolated init() {}
    /// The one-character string of function key `code`, or "" when `code` is not a Unicode scalar.
    public static func string(_ code: Int) -> String {
        UInt32(exactly: code).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
    }
}
