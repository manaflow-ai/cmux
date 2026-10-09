import AppKit

// cmux: what the vendored TranscriptAccess (MessagesLab's Selection) asks of
// the standalone app that Home does not have: MessagesLab's selection e2e
// logger (SelectionCheck.swift, a test driver) and its Pager (Home pages
// through HomeStore, HomeProjection).

/// MessagesLab's selection e2e log: nothing to log in Home.
enum SelectionCheck {
    static func log(_ s: SelState, plain: String) {}
    static func logMenu(_ titles: [String]) {}
    static func logEvent(_ name: String, _ fields: [String: Any]) {}
}

/// Home has no MessagesLab pager: a selection is copied from the loaded
/// HomeStore window only (`pager` is nil, so a copy that reaches rows outside
/// it copies nothing, as MessagesLab without a pager).
struct HomeNoPager {
    struct Source { func decode(_ range: Range<Int>) -> [Message] { [] } }
    let source = Source()
}

extension ChatController {
    var pager: HomeNoPager? { nil }
}
