/// What Close All Tabs asks before it closes every tab (as Safari's grid does).
struct CloseAllConfirmation: Equatable {
    var count: Int

    /// The destructive button.
    var confirmTitle: String { count == 1 ? "Close 1 Tab" : "Close All \(count) Tabs" }
    /// The line under the question.
    var message: String { "This can’t be undone." }
}
