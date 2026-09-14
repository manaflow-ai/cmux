import Foundation
import Observation

/// Shared port choices for this app session; the registry retires a machine's
/// models before it removes that machine's listeners and credentials.
@MainActor
@Observable
final class CloudPortAccessStore {
    var coordinator: CloudTunnelCoordinator?
    private(set) var models: [CloudHubPortForwarder.Key: CloudPortAccessModel] = [:]

    func model(machineID: String, target: CloudPortForwardTarget, make: () -> CloudPortAccessModel) -> CloudPortAccessModel {
        let key = CloudHubPortForwarder.Key(machineID: machineID, port: target.port)
        if let existing = models[key], existing.phase != .closed {
            existing.updateTarget(target)
            return existing
        }
        let model = make()
        models[key] = model
        model.observe()
        return model
    }

    func remove(machineID: String) async {
        for key in models.keys.filter({ $0.machineID == machineID }) {
            if let model = models.removeValue(forKey: key) {
                await model.retire()
            }
        }
    }
}
