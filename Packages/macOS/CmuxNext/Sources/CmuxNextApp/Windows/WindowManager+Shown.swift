extension WindowManager {
    /// The open window that already lists `workspaceID`, nil when none does: all a link from
    /// model output may show it in (DeepLinkNavigator, media safety R8), as it never claims a
    /// workspace into a window or opens one. ``reveal(workspaceID:)`` uses it first.
    func shownWindow(workspaceID: String) -> WindowController? {
        let value = registry.value
        guard let owner = value.owner(of: workspaceID), value.window(owner)?.isOpen == true else { return nil }
        return controller(for: owner)
    }
}
