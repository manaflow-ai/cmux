public import Foundation

/// Where the computer use step reads the helper's grants and sends the
/// user to grant them. The App answers it from the helper's
/// `cua.permissions` read; `MockComputerUsePermissionSource` stands in for
/// the gallery and tests.
@MainActor
public protocol ComputerUsePermissionSource: AnyObject {
    /// The helper app to drag into a list (its icon and name show on the
    /// tile): a Developer ID signed helper only. Nil when this build has
    /// none (a dev build without a release, NIGHTLY or RC helper installed);
    /// Allow then reports computer use unavailable and offers nothing.
    var helperAppURL: URL? { get }
    /// The grants now, then each change (a grant in System Settings), until the step ends.
    func permissions() -> AsyncStream<ComputerUsePermissions>
    /// Opens the pane in System Settings.
    func openSettings(_ pane: ComputerUsePermissionPane)
}
