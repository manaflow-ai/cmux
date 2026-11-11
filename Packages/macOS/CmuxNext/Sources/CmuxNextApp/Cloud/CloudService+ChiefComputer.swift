import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHomeEngine

/// A Cloud computer takes the name of the Chief it is for: "Ada’s Computer", and "Ada 2’s Computer" when
/// that name is taken. The name is the machine's own, so the sidebar, the CLI and the iPhone show it too.
extension CloudService {
    /// Every name a new machine must not take: the account's machines and the creates on their way.
    var machineNamesTaken: [String] {
        machines.cloud.map(\.machine.title) + creations.all.compactMap(\.pinnedMachineName) + machineNamesInFlight
    }

    /// The free name for a computer of the Chief named `chief`.
    func chiefComputerName(for chief: String) -> String {
        CloudMachine.defaultName(taken: machineNamesTaken, base: HomeEngineStrings.computerName(chief),
                                 numbered: { HomeEngineStrings.computerName("\(chief) \($0)") })
    }

    /// Names `machineID` after the Chief using it, while it still has a generic name; a name a person
    /// gave it stays. A rename that fails leaves the old name, which the next card to open tries again.
    func nameForChief(_ machineID: String, chief: String) async {
        guard let title = machines.session(machineID)?.machine.title, CloudMachine.isGenericName(title) else { return }
        do {
            try await renameMachine(machineID, to: chiefComputerName(for: chief))
        } catch {
            logger.error("naming \(machineID, privacy: .public) after its Chief: \(String(describing: error), privacy: .public)")
        }
    }
}

extension CloudMachine {
    /// Whether `title` is the name cmux gives a machine nobody named ("Cloud Machine 5").
    static func isGenericName(_ title: String) -> Bool {
        isDefaultName(title, base: CloudStrings.defaultMachineName, numbered: CloudStrings.defaultMachineName(numbered:))
    }
}

extension HomeChiefCloudComputer {
    /// `machine`, as the Chief card's picker offers it.
    init(_ machine: CloudMachine, id: String) {
        self.init(id: id, title: machine.title, isGenericName: CloudMachine.isGenericName(machine.title), isInternal: machine.isAgentInfrastructure)
    }
}
