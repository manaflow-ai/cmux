import Foundation

extension WorkspacesModel {
    /// Replaces the workspace order through one `tabs` assignment.
    ///
    /// `tabs` is the publication boundary used by the app to reconcile mounted
    /// workspace portals. Mutating an array in place (for example, `remove`
    /// followed by `insert`) publishes an intermediate order that can omit the
    /// selected workspace and tear down its terminal surface. Reorder callers
    /// use this helper to keep every observable snapshot self-consistent.
    func replaceTabs(_ transform: ([Tab]) -> [Tab]) {
        tabs = transform(tabs)
    }
}
