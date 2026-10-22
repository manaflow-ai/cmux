public import CmuxNextIcons
import Foundation

/// What kind of computer a machine is, for its default icon: a remote group's header and a remote
/// workspace's machine mark draw it unless the person set the machine's own icon
/// (remote-groups-per-machine-DESIGN.md R1).
///
/// The form is a default only, read from the machine's kind and name: a Cloud machine is a cloud, a
/// name with "mini" is a Mac mini, "macbook"/"mbp"/"mba"/"laptop" a laptop, "imac"/"studio"/"macpro"
/// a desktop Mac, and any other remote machine a server. The person's icon (`machine.setIcon`) always wins.
public nonisolated enum SidebarMachineForm: Hashable, Sendable {
    /// This Mac.
    case thisMac
    /// A Cloud machine (a Freestyle VM).
    case cloud
    /// A Mac mini.
    case macMini
    /// A MacBook or another laptop.
    case laptop
    /// An iMac, a Mac Studio or a Mac Pro.
    case desktop
    /// Any other remote computer: a Linux server, a VM, a paired server.
    case server

    /// The form of `machine`, from its kind and name.
    public init(_ machine: SidebarMachine) {
        self.init(kind: machine.kind, name: machine.name)
    }

    /// The form of a machine of `kind` named `name`.
    public init(kind: SidebarMachine.Kind, name: String) {
        switch kind {
        case .local: self = .thisMac
        case .cloud: self = .cloud
        case .ssh, .server:
            self = .server
        }
    }

    /// The form's icon.
    public var icon: IconName {
        switch self {
        case .thisMac, .laptop: .machineLocal
        case .cloud: .cloud
        case .macMini: .machineMac
        case .desktop: .machine
        case .server: .machineRemote
        }
    }
}
