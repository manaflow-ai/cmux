import Foundation

/// The Chief conversation's notice while a turn waits for the compactor to
/// summarize the view: `<chief home>/state/settle.json`, written by the host
/// only while a turn waits (optchat-chief settle_status.rs). After a large
/// import the first settle takes minutes; the notice says how far it is.
nonisolated struct ChiefSettleNotice {
    /// The notice for the file's contents; nil when it is not a wait.
    static func text(json: Data) -> String? { nil }
}
