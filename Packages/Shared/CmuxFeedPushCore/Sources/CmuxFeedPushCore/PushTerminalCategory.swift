/// The category the Mac relay sets on terminal alerts (bells, `cmux.terminal`).
/// A tap routes through `cmux.route`; there is no inline action until the
/// terminal input path exists on the phone (a1-shell.md 1.3).
public struct PushTerminalCategory: Hashable, Sendable {
    public static let terminal = "cmux.terminal"

    public let identifier: String

    public init(identifier: String = PushTerminalCategory.terminal) {
        self.identifier = identifier
    }
}
