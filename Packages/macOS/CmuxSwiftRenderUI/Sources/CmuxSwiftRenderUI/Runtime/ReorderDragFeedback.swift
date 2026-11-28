/// The discrete projected drop intent exposed to a JavaScript sidebar.
struct ReorderDragFeedback: Equatable {
    let id: String
    let index: Int
    let side: String
    let block: Bool

    var payload: [String: Any] {
        ["id": id, "index": index, "side": side, "block": block]
    }
}
