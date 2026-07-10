import Foundation

struct RPCStackTokenTaskState {
    let id: UUID
    let task: Task<String, any Error>
    var waiters: Int
    var timedOutUntil: UInt64?
}
