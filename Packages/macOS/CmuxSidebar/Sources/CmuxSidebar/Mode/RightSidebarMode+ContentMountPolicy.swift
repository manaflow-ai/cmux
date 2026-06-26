extension RightSidebarMode {
    /// Whether the right-sidebar content subtree should be mounted. Content stays
    /// mounted once it has been shown (`hasMountedContent`) so toggling the
    /// sidebar hidden does not tear down and rebuild the panel; a never-shown
    /// sidebar stays lazy until it first becomes visible.
    public static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}
