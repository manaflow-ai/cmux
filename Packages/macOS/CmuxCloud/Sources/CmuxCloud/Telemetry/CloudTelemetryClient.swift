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
    /// A random id for this app install (one per bundle id), exported as
    /// `service.instance.id`. It identifies no user or account.
    public let instanceId: String?

    public static func current(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        flavor: BuildFlavor = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
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
            architecture: architecture,
            instanceId: installInstanceID(defaults: defaults)
        )
    }

    static let instanceIDDefaultsKey = "cmux.telemetry.instanceID"

    /// The stored install id, created on first use.
    static func installInstanceID(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: instanceIDDefaultsKey),
           let uuid = UUID(uuidString: stored) {
            return uuid.uuidString.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: instanceIDDefaultsKey)
        return created
    }

    public init(
        channel: String,
        tag: String?,
        version: String,
        build: String,
        revision: String,
        osVersion: String,
        architecture: String,
        instanceId: String? = nil
    ) {
        self.channel = channel
        self.tag = tag
        self.version = version
        self.build = build
        self.revision = revision
        self.osVersion = osVersion
        self.architecture = architecture
        self.instanceId = instanceId
    }
}
