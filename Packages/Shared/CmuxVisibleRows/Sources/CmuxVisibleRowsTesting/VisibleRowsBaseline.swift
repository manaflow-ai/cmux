/// The lists registered with the visible-rows contract that do not meet it yet: name (`VisibleRowsFixture.name`) to
/// why, and the lane fixing it. `VisibleRowsContract.check` runs these inside `withKnownIssue`, so a fix that makes one
/// pass fails its test until the fix deletes its line here. Lines are only deleted: a new list meets the contract, or
/// its PR says why it may not. The count of lines is the number of known failures.
public enum VisibleRowsBaseline {
    public static let knownFailures: [String: String] = [
        "notifications panel": "a new row view for every ledger entry on every render, all measured; the ledger has no cap "
            + "(macOS NotificationsPanelController.render; fix: visible-only-macos-lists)",
    ]
}
