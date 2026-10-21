/// One machine of the Cloud section (a value snapshot).
nonisolated struct MachineSectionRow: Identifiable, Hashable, Sendable {
    /// The machine id (`workspace.newOnMachine`'s `machine`).
    let id: String
    let name: String
    let isConnected: Bool
    let isLocal: Bool
}
