/// Which Mac the aggregated workspace list is filtered to.
///
/// A pure value held as `@State` in the list view so the device filter composes
/// with the search field without any reference to the shell store below the
/// list's snapshot boundary.
enum WorkspaceDeviceFilter: Equatable, Hashable {
    /// Show every paired Mac's workspaces.
    case all
    /// Show only the workspaces sourced from the Mac with this device id.
    case device(String)

    /// Whether a section for `deviceID` passes the filter.
    func matches(deviceID: String) -> Bool {
        switch self {
        case .all:
            return true
        case let .device(id):
            return id == deviceID
        }
    }
}
