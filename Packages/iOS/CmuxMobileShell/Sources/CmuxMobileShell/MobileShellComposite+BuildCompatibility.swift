internal import CmuxMobileShellModel
internal import Foundation

@MainActor
extension MobileShellComposite {
    /// Whether authenticated host status belongs to this iOS build's audience.
    func macBuildIsCompatible(instanceTag: String?) -> Bool {
        buildCompatibilityPolicy?.allows(instanceTag: instanceTag) ?? true
    }

    /// Removes registry app instances this iOS build is not allowed to use.
    func compatibleRegistryDevices(_ devices: [RegistryDevice]) -> [RegistryDevice] {
        guard let buildCompatibilityPolicy else { return devices }
        return devices.compactMap { device in
            let compatibleInstances = device.instances.filter {
                buildCompatibilityPolicy.allows(instanceTag: $0.tag)
            }
            guard !compatibleInstances.isEmpty else { return nil }
            var compatibleDevice = device
            compatibleDevice.instances = compatibleInstances
            compatibleDevice.lastSeenAt = compatibleInstances
                .map(\.lastSeenAt)
                .max() ?? .distantPast
            return compatibleDevice
        }
    }

    /// Removes incompatible Mac instances from live presence updates.
    func compatiblePresenceUpdate(_ update: PresenceUpdate) -> PresenceUpdate? {
        guard let buildCompatibilityPolicy else { return update }
        switch update {
        case .snapshot(var snapshot):
            snapshot.devices = snapshot.devices.compactMap { device in
                let instances = device.instances.filter {
                    buildCompatibilityPolicy.allows(instanceTag: $0.tag)
                }
                guard !instances.isEmpty else { return nil }
                var compatibleDevice = device
                compatibleDevice.instances = instances
                compatibleDevice.online = instances.contains(where: \.online)
                compatibleDevice.lastSeenAt = instances.map(\.lastSeenAt).max() ?? 0
                return compatibleDevice
            }
            return .snapshot(snapshot)
        case .online(let instance):
            return buildCompatibilityPolicy.allows(instanceTag: instance.tag)
                ? .online(instance) : nil
        case .offline(let instance, let reason):
            return buildCompatibilityPolicy.allows(instanceTag: instance.tag)
                ? .offline(instance, reason: reason) : nil
        case .seen(let deviceId, let tag, let lastSeenAt):
            return buildCompatibilityPolicy.allows(instanceTag: tag)
                ? .seen(deviceId: deviceId, tag: tag, lastSeenAt: lastSeenAt) : nil
        case .routes(let instance):
            return buildCompatibilityPolicy.allows(instanceTag: instance.tag)
                ? .routes(instance) : nil
        }
    }
}
