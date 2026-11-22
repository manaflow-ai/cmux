/// A value built once per change of its input: the Workspaces list's body runs on every
/// change it reads (a sheet, a key in the search field, the minute tick of a subtitle), and a
/// pass whose input is the same reuses the last value instead of modeling every row again
/// (perf-speed-of-light.md I1; Leo, 2026-11-04: "never ... acceptable ... linear time growth
/// degradation"). Not observable: it only caches what the body already read.
@MainActor
final class BuiltOncePerInput<Input: Equatable, Value> {
    private var last: (input: Input, value: Value)?
    /// How many values were built (tests).
    private(set) var builds = 0

    /// The value for `input`: the last one when `input` equals the last input, else `build()`.
    func value(_ input: Input, build: () -> Value) -> Value {
        if let last, last.input == input { return last.value }
        let value = build()
        builds += 1
        last = (input, value)
        return value
    }
}
