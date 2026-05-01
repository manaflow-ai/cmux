import AppKit
import Foundation

struct MobileMachineIdentity: Equatable, Sendable {
    let machineID: String
    let displayName: String
    let hostname: String
}

final class MachineIdentityStore {
    private enum Keys {
        static let machineID = "cmux.mobile.machineID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identity() -> MobileMachineIdentity {
        let machineID = persistedMachineID()
        let hostName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        let displayName = Host.current().localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileMachineIdentity(
            machineID: machineID,
            displayName: displayName?.isEmpty == false ? displayName! : hostName,
            hostname: hostName
        )
    }

    private func persistedMachineID() -> String {
        if let existing = defaults.string(forKey: Keys.machineID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Keys.machineID)
        return created
    }
}
