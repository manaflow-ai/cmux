/// Tabs whose engine reports every result of a find, not only its answer: a Chromium page's counts
/// while it searches, its final result, and a correction after the answer (``CEFFindRequests``).
/// The find bar shows each, as Chrome's shows each result it gets
/// (`FindBarController::OnFindResultAvailable`, chrome/browser/ui/find_bar/find_bar_controller.cc).
public protocol BrowserFindUpdating: AnyObject {
    /// ``BrowserTab/find(_:direction:caseSensitive:)``, with `update` called for each result of
    /// this search until the next search or ``BrowserTab/clearFind()``.
    ///
    /// Every final result goes to `update`, and the answer is the first one, so a caller that
    /// shows the updates shows the answer only when no update came (an empty query, no page).
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool,
              update: @escaping (BrowserFindResult) -> Void) async -> BrowserFindResult
}
