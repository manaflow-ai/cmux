/// Workspace counts for the Mac title picker: how many list rows each
/// selection would show if chosen. Computed once per snapshot build so menu
/// rows read a stamped number instead of rescanning the workspace list.
struct WorkspaceMacPickerCounts: Equatable {
    static let empty = WorkspaceMacPickerCounts(all: 0, byMachineID: [:])

    /// Rows the All Computers selection would show.
    let all: Int
    /// Rows each machine entry (pairing id or bare device id) would show.
    /// A machine with no matching rows has no entry; read via `count(for:)`.
    let byMachineID: [String: Int]

    func count(for machineID: String) -> Int {
        byMachineID[machineID] ?? 0
    }
}
