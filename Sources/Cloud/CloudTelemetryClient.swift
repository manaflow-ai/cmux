import Foundation

struct CloudTelemetryClient: Codable, Sendable, Equatable {
    let channel: String
    let version: String
    let build: String
    let revision: String
    let osVersion: String
    let architecture: String

    static func current(info: [String: Any] = Bundle.main.infoDictionary ?? [:], flavor: BuildFlavor = .current) -> Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(
            channel: flavor == .stable ? "production" : flavor.rawValue,
            version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0",
            revision: info["CMUXCommit"] as? String ?? "unknown",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture
        )
    }
}
