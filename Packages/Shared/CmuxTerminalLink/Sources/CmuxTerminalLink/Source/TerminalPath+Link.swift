public import CmuxLink
public import CmuxTerminalRenderCore

extension TerminalPath {
    /// The badge for a link path: relayed paths never read as direct.
    public init(_ kind: PathKind) {
        switch kind {
        case .direct, .p2p: self = .direct
        case .turn, .relay: self = .relayed
        }
    }
}
