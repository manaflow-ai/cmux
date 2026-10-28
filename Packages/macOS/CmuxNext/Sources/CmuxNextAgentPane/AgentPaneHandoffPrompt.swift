import Foundation

/// A Cloud chat's prompt names the hand-off turn it starts (cloud work mode): the page sends it as
/// `handoff-<turn>-<id>`, where `<id>` is the prompt's own id (`cloud.handoffTurn`, the webview's
/// cloudHandoffTurn.ts), and acpmux on the machine reports that turn (cmux-tui acpmux
/// `daemon/cloud_handoff.rs` `named_turn`: a turn of 1 to 15 digits with no leading zero).
///
/// The turn is a label on the same prompt: a gesture ticket bound to the prompt's own id (the
/// Send's, a held prompt's, a seeded prompt's) is the same prompt's ticket under the label
/// (``AgentPaneGesturePick``). It allows that prompt and nothing else.
public nonisolated enum AgentPaneHandoffPrompt {
    public static let prefix = "handoff-"

    /// The prompt's own id: `id` without a hand-off turn's `handoff-<turn>-`, else `id` as it is.
    public static func ownID(_ id: String) -> String {
        guard id.hasPrefix(prefix) else { return id }
        let rest = id.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return id }
        let turn = rest[..<dash], own = rest[rest.index(after: dash)...]
        guard (1...15).contains(turn.count), turn.first != "0", turn.allSatisfy({ $0.isASCII && $0.isNumber }), !own.isEmpty else { return id }
        return String(own)
    }
}
