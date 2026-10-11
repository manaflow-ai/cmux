import Foundation

nonisolated struct RustSectionID: Codable, Equatable {
    var kind: String
    var id: String?

    init(_ value: SectionID) {
        switch value {
        case .pinned:
            kind = "pinned"
            id = nil
        case let .machine(machine):
            kind = "machine"
            id = machine.rawValue
        }
    }

    var swiftValue: SectionID? {
        switch kind {
        case "pinned": .pinned
        case "machine": id.map(MachineID.init).map(SectionID.machine)
        default: nil
        }
    }
}
