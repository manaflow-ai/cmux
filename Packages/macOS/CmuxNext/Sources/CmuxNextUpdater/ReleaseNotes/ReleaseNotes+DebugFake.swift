extension ReleaseNotes {
    /// Release notes for a fake staged update (`debug.updater {action: "stage"}`, UPDATE-CARD
    /// screenshots and proofs): `changes` items, newest first, each with an author and a PR number.
    public static func debugFake(version: String, changes: Int) -> ReleaseNotes {
        let titles = ["Update card with release notes above the sidebar footer", "Restart to update keeps terminals and agents running",
                      "Faster workspace switching with many tabs", "Browser tabs restore their scroll position",
                      "Agent pane remembers the last model", "Fix a crash when closing a split during a drag"]
        let authors = ["lawrencecchen", "contributor", "maintainer"]
        let items = (0..<changes).map { index in
            ChangeItem(title: titles[index % titles.count], author: authors[index % authors.count], pr: 18_000 - index)
        }
        let summary = [SummaryLine(group: "new", title: "Update cards show the changelog and build date"),
                       SummaryLine(group: "fixed", title: "A check while an update waits shows Restart to Update"),
                       SummaryLine(group: "changed", title: "Short update titles keep the version in the detail")]
        return ReleaseNotes(version: 1, build: "0", shortVersion: version, date: "2026-10-10", highlights: [],
                            changes: items.map(\.title), items: items, summary: summary)
    }
}
