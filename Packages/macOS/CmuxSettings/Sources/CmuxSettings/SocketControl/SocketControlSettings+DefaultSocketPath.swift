public import Darwin
public import Foundation

extension SocketControlSettings {
    /// The default socket path for the current build variant (before override handling).
    public static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        if isDebugBuild,
           isBareDebugBundleIdentifier(
               bundleIdentifier,
               baseDebugBundleIdentifier: baseDebugBundleIdentifier
           ),
           launchTag(environment: environment) == nil,
           environment["CMUX_SOCKET_PATH"]?.isEmpty != false,
           let xctestPath = xctestDebugSocketPath(environment: environment) {
            return xctestPath
        }

        return SocketPathMarkerFiles.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: isDebugBuild,
            stableSocketPath: resolvedStableDefaultSocketPath(
                currentUserID: currentUserID,
                probeStableDefaultPathEntry: probeStableDefaultPathEntry
            ),
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
    }
}

private func isBareDebugBundleIdentifier(
    _ bundleIdentifier: String?,
    baseDebugBundleIdentifier: String
) -> Bool {
    bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) == baseDebugBundleIdentifier
}

private func xctestDebugSocketPath(environment: [String: String]) -> String? {
    let indicators = [
        "XCTestSessionIdentifier",
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundle",
        "XCInjectBundleInto",
        "DYLD_INSERT_LIBRARIES",
    ]
    guard let source = indicators.compactMap({ key -> String? in
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if key == "DYLD_INSERT_LIBRARIES",
           !value.contains("libXCTest") {
            return nil
        }
        return value
    }).first else {
        return nil
    }

    let hash = source.utf8.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
        (partial ^ UInt64(byte)) &* 0x100000001b3
    }
    return "/tmp/cmux-xctest-\(String(hash, radix: 16)).sock"
}
