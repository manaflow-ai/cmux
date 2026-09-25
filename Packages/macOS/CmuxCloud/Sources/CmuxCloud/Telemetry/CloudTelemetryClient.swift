import CmuxSettings
import Foundation

public struct CloudTelemetryClient: Codable, Sendable, Equatable {
    public let channel: String
    /// The tagged Debug app identity. This survives a backend outage because
    /// it is carried by the queued client span rather than inferred from the
    /// server deployment environment.
    public let tag: String?
    public let version: String
    public let build: String
    public let revision: String
    let osVersion: String
    public let architecture: String

    public static func current(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        flavor: BuildFlavor = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(
            channel: flavor == .stable ? "production" : flavor.rawValue,
            tag: flavor == .dev ? environment["CMUX_TAG"] : nil,
            version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0",
            revision: info["CMUXCommit"] as? String ?? "unknown",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture
        )
    }
}
