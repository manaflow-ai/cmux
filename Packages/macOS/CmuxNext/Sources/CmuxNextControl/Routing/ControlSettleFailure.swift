import CmuxNextActions

/// Why ``ControlRouter/settle(opWork:scope:action:method:deadline:replyBy:)`` ended without a
/// snapshot. `action.run` maps both cases to one error; `action.batch` names the op that failed.
enum ControlSettleFailure: Error {
    /// Op `op`'s work failed (the first op whose work did) with `failure`; `failed` lists every
    /// op whose work failed, in order.
    case work(op: Int, failed: [Int], ActionWorkFailure)
    /// A missed deadline, or a failed daemon command of the request's scope: no op owns it.
    case other(ControlError)
}
