public import Foundation

/// A machine's identity color: the color the person picked for it
/// (`appearance.machineColors`, MachineColorOverrides), else one of the theme's
/// accents, picked by a stable hash of the machine's name (trimmed, lowercased),
/// so each machine keeps one color on every row, tab and chip that names it. The
/// automatic pick is AgentPresenceColor's pick over the name, which the agent
/// pane's machineColor.ts repeats, so the sidebar and the composer chip agree.
public nonisolated struct MachineColor: Sendable {
    /// The machine's name as cmux shows it.
    public let name: String

    public init(name: String) { self.name = name }

    /// The name colors are keyed by: trimmed and lowercased, so "Big-Red " and "big-red" are one machine.
    public var key: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
