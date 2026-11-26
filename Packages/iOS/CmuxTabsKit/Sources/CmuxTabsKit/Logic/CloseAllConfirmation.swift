/// What Close All Tabs asks before it closes every tab (as Safari's grid does).
struct CloseAllConfirmation: Equatable {
    /// The tabs shown when the person asked: exactly these close on confirm.
    var ids: [String]

    var count: Int { ids.count }
    /// The destructive button.
    var confirmTitle: String { count == 1 ? "Close 1 Tab" : "Close All \(count) Tabs" }
    /// The line under the question.
    var message: String { "This can’t be undone." }
}
