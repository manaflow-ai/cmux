extension SidebarDropPlanner {
    /// Sidebar workspace drop targets sorted once for repeated pointer hit testing.
    public struct OrderedWorkspaceDropTargets: Equatable {
        let targets: [WorkspaceDropTarget]

        /// Creates a target collection ordered by each row's vertical position.
        ///
        /// - Parameter targets: The row-frame targets to sort for repeated hit testing.
        public init(_ targets: [WorkspaceDropTarget]) {
            self.targets = targets.sorted { lhs, rhs in
                lhs.frame.minY < rhs.frame.minY
            }
        }

        /// Returns whether there are no workspace targets to hit test.
        public var isEmpty: Bool {
            targets.isEmpty
        }
    }
}
