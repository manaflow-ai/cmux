/// Which documents an agent has scripted and which hold a filled Secure Store login, per tab
/// (cmux https://github.com/manaflow-ai/cmux/issues/25830). A document is named by its time origin
/// read in cmux's isolated script world (``BrowserPageScripts/documentProbe``), which page and agent
/// scripts cannot reach or fake, so both marks end with the document: a navigation gives a fresh,
/// clean one.
///
/// - An agent script (`eval`, `wait --function`) on a document holding a filled login is refused,
///   so it cannot read the password back.
/// - `fill_login` on a document an agent scripted is refused, so a hooked setter, listener or
///   rewritten form action cannot catch it.
///
/// Check and mark happen in one actor step, so an eval and a fill racing on one document cannot
/// both pass.
actor BrowserLoginGuards {
    /// Documents remembered per tab and kind; the oldest drop out first.
    static let remembered = 64

    private var scripted: [String: [String]] = [:]
    private var filled: [String: [String]] = [:]
    /// Tabs where an agent script ran on a document the probe could not name: no fill there.
    private var unnamed: Set<String> = []

    /// An agent script is about to run on `document` (nil: unnamed). False when that document
    /// holds a filled login; else it is marked scripted.
    func beginScript(tab: String, document: String?) -> Bool {
        guard let document else {
            unnamed.insert(tab)
            return true
        }
        if filled[tab]?.contains(document) == true { return false }
        Self.remember(document, in: &scripted, tab: tab)
        return true
    }

    /// Marks `document` scripted after a script ran (it may have moved to a new document).
    func markScripted(tab: String, document: String?) {
        guard let document else {
            unnamed.insert(tab)
            return
        }
        Self.remember(document, in: &scripted, tab: tab)
    }

    /// A login is about to be filled into `document`. False when an agent scripted it (or a
    /// document of this tab the probe could not name); else it is marked filled.
    func beginFill(tab: String, document: String) -> Bool {
        if unnamed.contains(tab) || scripted[tab]?.contains(document) == true { return false }
        Self.remember(document, in: &filled, tab: tab)
        return true
    }

    /// The fill set nothing on `document` (no login field, or the page moved first): scripts may
    /// run there again.
    func forgetFill(tab: String, document: String) {
        filled[tab]?.removeAll { $0 == document }
    }

    private static func remember(_ document: String, in table: inout [String: [String]], tab: String) {
        var list = table[tab] ?? []
        guard !list.contains(document) else { return }
        list.append(document)
        if list.count > remembered { list.removeFirst(list.count - remembered) }
        table[tab] = list
    }
}
