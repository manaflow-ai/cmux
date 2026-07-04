/// One process currently holding a power assertion that keeps the Mac or its
/// display awake, as reported by `pmset -g assertions`.
public struct MacPowerAssertionHolder: Sendable, Equatable, Codable {
    /// The owning process id.
    public let pid: Int

    /// The owning process name, such as `caffeinate`, `cmux`, or `Google Chrome`.
    public let processName: String

    /// The assertion types this process holds, such as `PreventUserIdleSystemSleep`.
    public let assertionTypes: [String]

    /// The human-readable assertion reason from pmset's `named:` field, if present.
    public let detail: String?

    /// Creates one parsed power assertion holder.
    public init(pid: Int, processName: String, assertionTypes: [String], detail: String?) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
        self.detail = detail
    }
}
