import CmuxSimulator
import Foundation

func simulatorCameraCanSwitchSource(
    _ configuration: SimulatorCameraConfiguration,
    configuredTargetCount: Int,
    hasProducer: Bool
) -> Bool {
    !configuration.isDisabled
        && configuration.targetBundleIdentifier == nil
        && configuredTargetCount > 0
        && hasProducer
}

func simulatorCameraProcessIdentifier(fromLaunchOutput output: String) -> Int32? {
    guard let suffix = output.split(separator: ":").last,
          let value = Int32(suffix.trimmingCharacters(in: .whitespacesAndNewlines)),
          value > 0 else { return nil }
    return value
}

func simulatorCameraIsInstalledUserApplication(
    bundleIdentifier: String,
    listApplicationsOutput: String
) -> Bool {
    guard !bundleIdentifier.isEmpty,
          let data = listApplicationsOutput.data(using: .utf8),
          let applications = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
          ) as? [String: Any],
          let record = applications[bundleIdentifier] as? [String: Any],
          (record["ApplicationType"] as? String)?.caseInsensitiveCompare("User")
            == .orderedSame,
          let path = record["Path"] as? String,
          path.hasSuffix(".app") else { return false }
    return true
}

func simulatorCameraTargetStatuses(
    configuredBundleIdentifiers: Set<String>,
    processIdentifiers: [String: Int32],
    attachedProcessIdentifiers: Set<Int32>
) -> [SimulatorCameraTargetStatus] {
    configuredBundleIdentifiers.map { bundle in
        let processIdentifier = processIdentifiers[bundle]
        return SimulatorCameraTargetStatus(
            bundleIdentifier: bundle,
            processIdentifier: processIdentifier,
            isAlive: processIdentifier != nil,
            isAttached: processIdentifier.map(attachedProcessIdentifiers.contains) == true
        )
    }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
}

func simulatorCameraShouldReinstateExitedTarget(
    configuredBundleIdentifiers: Set<String>,
    processIdentifiers: [String: Int32],
    bundleIdentifier: String,
    exitedProcessIdentifier: Int32
) -> Bool {
    configuredBundleIdentifiers.contains(bundleIdentifier)
        && processIdentifiers[bundleIdentifier] == exitedProcessIdentifier
}

func simulatorCameraShouldAutomaticallyReinstateExitedTarget(
    configuredBundleIdentifiers: Set<String>,
    processIdentifiers: [String: Int32],
    automaticReinjectionAttempted: Set<String>,
    bundleIdentifier: String,
    exitedProcessIdentifier: Int32
) -> Bool {
    !automaticReinjectionAttempted.contains(bundleIdentifier)
        && simulatorCameraShouldReinstateExitedTarget(
            configuredBundleIdentifiers: configuredBundleIdentifiers,
            processIdentifiers: processIdentifiers,
            bundleIdentifier: bundleIdentifier,
            exitedProcessIdentifier: exitedProcessIdentifier
        )
}
