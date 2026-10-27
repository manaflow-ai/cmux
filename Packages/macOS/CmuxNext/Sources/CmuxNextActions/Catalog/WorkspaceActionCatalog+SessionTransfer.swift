// Moving live sessions here from another local cmux build (dev, nightly,
// classic): `SessionTransferService` in the App. Titles live in
// ActionCatalog.xcstrings.

nonisolated extension WorkspaceActionCatalog {
    static func sessionTransferActions() -> [ActionDescriptor] {
        // A person picks the sessions in a dialog (cx-yxmkh), so it is person-only
        // with no CLI verb: an agent must not put the picker in front of the person.
        // Scripts and agents move sessions with `session.transfer.peers` and `.pull`.
        var moveFromBuild = ActionDescriptor(
            id: "session.moveFromBuild",
            title: String(localized: "action.session.moveFromBuild", defaultValue: "Move Sessions from Another cmux Build…", bundle: .module),
            keywords: ["move", "transfer", "import", "dev", "nightly", "build", "session", "classic", "migrate"], category: .workspace,
            symbol: "arrow.right.arrow.left", surfaces: [.palette]
        )
        moveFromBuild.isPersonOnly = true
        // The moves run after the person answers the picker, longer than a
        // terminal start: the run ends when every chosen session has moved.
        moveFromBuild.waitsForResult = true
        return [moveFromBuild]
    }
}
