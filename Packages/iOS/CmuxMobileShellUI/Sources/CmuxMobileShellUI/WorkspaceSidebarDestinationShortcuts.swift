#if os(iOS)
/// The top-level destinations a phone split sidebar hosts, offered from the
/// workspace detail bar while the sidebar is hidden. Its presence also marks
/// the detail as part of a phone split layout (the unfolded iPhone Duo).
struct WorkspaceSidebarDestinationShortcuts {
    struct Item: Identifiable {
        let destination: MobilePrimaryTab
        let title: String

        var id: MobilePrimaryTab { destination }
    }

    let items: [Item]
    /// The destination the hidden sidebar currently shows.
    let current: MobilePrimaryTab
    /// Selects the destination and reveals the sidebar that renders it.
    let open: (MobilePrimaryTab) -> Void
}
#endif
