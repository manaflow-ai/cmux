import AppKit

/// The key-equivalent character of an AppKit function key (`NSPageUpFunctionKey`
/// and the others are Unicode private-use scalars, U+F700 and up). Never traps:
/// a code that is not a scalar gives "" (FunctionKeyCharacterTests checks
/// every code the app uses).
nonisolated enum FunctionKeyCharacter {
    static func string(_ code: Int) -> String {
        UInt32(exactly: code).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
    }
}
