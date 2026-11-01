/// One running program in a terminal that Quit keeps.
public struct QuitProgram: Equatable, Sendable {
    public var name: String
    /// CPU time of the terminal's processes other than its shell.
    public var cpuNanos: UInt64

    public init(name: String, cpuNanos: UInt64) {
        self.name = name
        self.cpuNanos = cpuNanos
    }
}
