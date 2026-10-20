public import CmuxNextDesign

nonisolated extension SidebarTunables {
    /// The Update Ready popup shows each change's picture inline (Leo 2026-10-19). Off until a
    /// nightly-next has carried it: the pictures are inlined from the staged notes (the signed
    /// hash, the bundled copy, the cache or the first-party site) after the text shows.
    public static let updateCardPictures = Tunable<Bool>.toggle(
        "sidebar.updateCard.pictures", .sidebar, "Update popup pictures",
        help: "The Update Ready popup shows each change's screenshot inline, under its text.",
        default: false, code: "SidebarTunables.updateCardPictures")
}
