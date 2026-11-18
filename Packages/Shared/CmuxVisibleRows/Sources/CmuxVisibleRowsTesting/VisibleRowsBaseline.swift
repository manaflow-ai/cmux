/// The lists registered with the visible-rows contract that do not meet it yet: name (`VisibleRowsFixture.name`) to
/// why, and the lane fixing it. `VisibleRowsContract.check` runs these inside `withKnownIssue`, so a fix that makes one
/// pass fails its test until the fix deletes its line here. Lines are only deleted or narrowed: a new list meets the
/// contract, or its PR says why it may not. The count of lines is the number of known failures.
public enum VisibleRowsBaseline {
    public struct Known: Sendable {
        /// What the list does today, and `fix: <lane>`.
        public var why: String
        /// Only issues whose message contains this are known (a list that meets every rule but one); nil: any.
        public var only: String?

        public init(_ why: String, only: String? = nil) { (self.why, self.only) = (why, only) }
    }

    public static let knownFailures: [String: Known] = [
        "notifications panel": Known("a new row view for every ledger entry on every render, all measured; the ledger has no cap "
            + "(macOS NotificationsPanelController.render; fix: visible-only-macos-lists)"),
        "automations list": Known("a change comes as a reload of both sources' whole lists, indexed and sorted again "
            + "(macOS AutomationsPage.reload; fix: visible-only-macos-lists)", only: "items walked"),
        "memory inspector": Known("a change comes as a reload of the whole view (/api/view answers every line) "
            + "(macOS ChiefMemoryInspectorModel.reload; fix: visible-only-macos-lists)", only: "items walked"),
    ]
}
