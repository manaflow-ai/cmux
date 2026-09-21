import Foundation

@MainActor
extension SurfaceCatalog {
    func notifyChange(for machine: SurfaceMachineID? = nil) {
        if let machine { pendingChangedMachines.insert(machine) }
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            let machines = self.pendingChangedMachines
            self.pendingChangedMachines.removeAll()
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: machines.isEmpty ? nil : ["machines": machines.map(\.rawValue)]
            )
        }
    }
}
