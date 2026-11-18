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
        "notifications panel": Known("the daemon answers each change with the whole ledger (up to 256 entries), and the panel reads "
            + "all of it to find what changed (macOS NotificationsPanelList.show; fix: visible-only-macos-lists)", only: "items walked"),
    ]
}
