import Foundation

/// The find-in-page request of one Chromium tab. Each `cmux_shim_find` gets a new find id, and
/// Chromium answers it with FIND_RESULT events carrying that id: counts while it searches the
/// page, then a final one, which answers the caller.
///
/// A result with another id belongs to an older search: in host mode it was already on the wire
/// when the newer search left cmux. It is dropped, as Chrome drops replies to a search that is no
/// longer current (`FindTabHelper::HandleFindReply`, components/find_in_page/find_tab_helper.cc).
/// A new search, Clear Find or the page ending answers a pending request with `.none`, so a
/// caller never waits forever.
///
/// Every result of the current search also goes to its `update` closure, until the next search
/// or Clear Find, after the answer too: the find pill shows each one, as Chrome's find bar shows
/// each result it gets (`FindBarController::OnFindResultAvailable`,
/// chrome/browser/ui/find_bar/find_bar_controller.cc). That includes a correction after the
/// answer: a Find Next sent while the previous step's results were still coming may be answered
/// by them, and its own final result follows.
struct CEFFindRequests {
    /// Answers the pending request once (a continuation's resume: it must not start a search).
    private var answer: ((BrowserFindResult) -> Void)?
    private var update: ((BrowserFindResult) -> Void)?
    /// The find id of the current search; 0 before the first one and after Clear Find.
    private(set) var currentID: Int32 = 0
    private var nextID: Int32 = 1

    /// Starts a request (answering any pending one with `.none`) and returns the find id to pass
    /// to Chromium.
    mutating func begin(answer: @escaping (BrowserFindResult) -> Void,
                        update: ((BrowserFindResult) -> Void)? = nil) -> Int32 {
        cancel()
        self.answer = answer
        self.update = update
        currentID = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        return currentID
    }

    /// A FIND_RESULT event. The final result of the current search answers the pending request.
    ///
    /// - Returns: What the current search's update closure gets, which the caller runs once this
    ///   call returned (the closure may start the next search); nil for a result of another
    ///   search, or a count while the page is still searched that has no match yet (the pill
    ///   never shows "No matches" before the end).
    mutating func result(findID: Int32, count: Int, active: Int, isFinal: Bool) -> Update? {
        guard findID != 0, findID == currentID else { return nil }
        let result = Self.findResult(count: count, active: active)
        if isFinal, let pending = answer {
            answer = nil
            pending(result)
        }
        guard isFinal || count > 0, let update else { return nil }
        return Update(result: result, deliver: update)
    }

    /// One result for the current search's update closure.
    struct Update {
        let result: BrowserFindResult
        let deliver: (BrowserFindResult) -> Void

        func run() { deliver(result) }
    }

    /// Answers a pending request with `.none` and ends the current search's updates.
    mutating func cancel() {
        let pending = answer
        answer = nil
        update = nil
        currentID = 0
        pending?(.none)
    }

    /// Chromium's count and 1-based active match ordinal (0 or less while none is active).
    static func findResult(count: Int, active: Int) -> BrowserFindResult {
        BrowserFindResult(matchFound: count > 0, matchCount: max(count, 0), currentIndex: count > 0 && active > 0 ? active : nil)
    }
}
