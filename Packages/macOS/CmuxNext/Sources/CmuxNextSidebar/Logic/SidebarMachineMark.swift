import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The computer a workspace row runs on (machine identity): its name in the row's
/// accessibility label. The row draws no glyph for it; the hover card names the
/// machine once, in its header (Leo 2026-11-02, on a card and row that said Cloud
/// four times: "the tiny cloud icon the repeated cloud cloud cloud"). Rows carry it
/// while the sidebar lists more than one machine; this Mac's rows only with
/// `sidebar.showLocalMachine` (off by default: another machine is the news).
public nonisolated struct SidebarMachineMark: Hashable, Sendable {
    /// The machine's name: the label.
    public var name: String
    public var kind: SidebarMachine.Kind
    /// The machine's own icon, when it is an SF Symbol or an emoji; with neither, its kind's
    /// symbol draws.
    public var symbol: String?
    public var emoji: String?

    public init(_ machine: SidebarMachine) {
        name = machine.name
        kind = machine.kind
        switch machine.icon {
        case let .symbol(name, _)?: symbol = name
        case let .emoji(glyph, _)?: emoji = glyph
        default: break
        }
    }

    /// The kind's glyph: a Mac, a Cloud machine, another computer.
    var kindIcon: IconName {
        switch kind {
        case .local: .machineLocal
        case .cloud: .cloud
        case .ssh, .server: .machineRemote
        }
    }
}
