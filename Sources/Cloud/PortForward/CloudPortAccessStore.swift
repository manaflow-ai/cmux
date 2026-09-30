import CmuxCloud
import Foundation
import Observation

/// Shared port choices for this app session; the registry retires a machine's
/// models before it removes that machine's listeners and credentials.
@MainActor
@Observable
final class CloudPortAccessStore {
    var coordinator: CloudTunnelCoordinator? {
        didSet {
            guard coordinator !== oldValue, let coordinator else { return }
            for model in models.values { model.attach(coordinator: coordinator) }
        }
    }
    private(set) var models: [CloudPortAccessKey: CloudPortAccessModel] = [:]

    func model(machineID: String, target: CloudPortForwardTarget, scheme: String = "http", make: () -> CloudPortAccessModel) -> CloudPortAccessModel {
        let key = CloudPortAccessKey(machineID: machineID, port: target.port, scheme: scheme.lowercased())
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
