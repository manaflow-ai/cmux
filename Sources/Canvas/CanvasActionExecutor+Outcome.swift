extension CanvasActionExecutor {
    enum Outcome: Equatable {
        /// The requested operation reached its model or mounted viewport.
        case completed
        /// The workspace is live, but the action does not apply to its current state.
        case notApplicable
        /// The immutable panel or mounted viewport needed by the action disappeared.
        case targetUnavailable
    }
}
