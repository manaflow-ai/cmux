import CmuxAgentReplica
import Foundation

struct AgentGUIStampedEntry: Hashable, Sendable {
    let entry: EntrySnapshot
    let isReplacement: Bool
}
