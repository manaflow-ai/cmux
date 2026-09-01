internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation

/// The single admission outcome for an authenticated Mac: channel/tag
/// compatibility (``MobileMacBuildCompatibilityPolicy``) first, then the
/// release-lane version floor (``MobileMacCompatPolicy``).
enum MacBuildAdmissionVerdict: Equatable {
    case allowed
    case buildIncompatible
    case macAppVersionTooOld(MobileMacCompatPolicy.Violation)
}

#if DEBUG
/// Dogfood switch for the release-lane version gate, which otherwise never
/// fires in development builds (they only admit development-tag Macs).
/// Launch the tagged Mac with `CMUX_DEBUG_MOBILE_APP_VERSION=<old version>`
/// and the phone/simulator with `CMUX_DEBUG_FORCE_MAC_COMPAT=1` (or the
/// launch argument `-CMUXDebugForceMacCompat YES`); the gate then evaluates
/// the dev Mac with its channel derived from the reported version grammar.
enum MobileMacCompatDebugOverride {
    static var forceEvaluation: Bool {
        ProcessInfo.processInfo.environment["CMUX_DEBUG_FORCE_MAC_COMPAT"] == "1"
            || UserDefaults.standard.bool(forKey: "CMUXDebugForceMacCompat")
    }
}
#endif

@MainActor
extension MobileShellComposite {
    /// Whether authenticated host status belongs to this iOS build's audience.
    func macBuildIsCompatible(instanceTag: String?) -> Bool {
        buildCompatibilityPolicy?.allows(instanceTag: instanceTag) ?? true
    }

    /// Admits an authenticated Mac through both compatibility authorities:
    /// the channel/tag policy, then the release-lane minimum-version policy
    /// for the tier matching this app's version.
    func authenticatedMacBuildAdmission(
        instanceTag: String?,
        clientNamespace: String? = nil,
        macAppVersion: String?,
        client: MobileCoreRPCClient
    ) -> MacBuildAdmissionVerdict {
        guard authenticatedMacBuildIsCompatible(
            instanceTag: instanceTag,
            clientNamespace: clientNamespace,
            macAppVersion: macAppVersion,
            client: client
        ) else {
            return .buildIncompatible
        }
        guard let channel = versionGateChannel(
            instanceTag: instanceTag,
            macAppVersion: macAppVersion
        ) else {
            return .allowed
        }
        guard let violation = macCompatPolicy.violation(
            iosVersion: versionGateIOSAppVersion,
            channel: channel,
            macAppVersion: macAppVersion
        ) else {
            return .allowed
        }
        return .macAppVersionTooOld(violation)
    }

    /// The release lane the version gate holds this Mac to, or `nil` when
    /// the Mac is outside the gate. Only the official audience is gated:
    /// development builds admit only development-tag Macs (rebuilt from
    /// source), and a `nil` policy is a preview/test fixture that admits
    /// everything. The DEBUG override makes the gate dogfoodable by deriving
    /// a dev Mac's channel from its reported version grammar.
    private func versionGateChannel(
        instanceTag: String?,
        macAppVersion: String?
    ) -> MobileMacCompatPolicy.Channel? {
        switch buildCompatibilityPolicy {
        case .official?:
            return MobileMacCompatPolicy.constrainedChannel(instanceTag: instanceTag)
        case .development?:
            #if DEBUG
            guard MobileMacCompatDebugOverride.forceEvaluation else { return nil }
            return macAppVersion?.contains("-nightly.") == true ? .nightly : .stable
            #else
            return nil
            #endif
        case nil:
            return nil
        }
    }

    /// Whether authenticated host status belongs to this build, including the
    /// narrow 0.64.17 Tailscale compatibility boundary.
    func authenticatedMacBuildIsCompatible(
        instanceTag: String?,
        clientNamespace: String? = nil,
        macAppVersion: String?,
        client: MobileCoreRPCClient
    ) -> Bool {
        buildCompatibilityPolicy?.allowsAuthenticatedHost(
            instanceTag: instanceTag,
            clientNamespace: clientNamespace,
            macAppVersion: macAppVersion,
            usesLocallyAuthorizedTailscaleRoute: client.usesLocallyAuthorizedTailscaleRoute
        ) ?? true
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
