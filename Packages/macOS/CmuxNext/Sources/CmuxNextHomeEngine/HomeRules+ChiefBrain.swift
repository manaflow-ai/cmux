import CmuxNextHomeModel
import Foundation

/// The Swift caller of the Rust `chief_brain` rules (cmux-tui/crates/cmux-home-rules/src/chief_brain):
/// when the app starts, watches, restarts, heals and times out its Chief's brain. Swift keeps the
/// I/O (files, signals, process lookups, sockets, timers) and runs the effects the rules return,
/// in order; the rules decide. A caller whose op fails takes a safe default (`(try? …) ?? default`).
extension HomeRules {
    /// Runs `chief_brain.NAME` on `input`.
    nonisolated static func chiefBrain<In: Encodable, Out: Decodable>(_ name: String, _ input: In) throws -> Out {
        try call("chief_brain." + name, input)
    }
}

/// A conversation participant as the `chief_brain` rules read it (`id`, and `kind`'s raw value).
nonisolated struct ChiefBrainParticipant: Codable, Sendable, Equatable {
    var id: String
    var kind: String?
}

/// A `chief_brain` `{"pid": …}` reply.
nonisolated struct ChiefBrainPidReply: Decodable {
    var pid: Int32?
}
