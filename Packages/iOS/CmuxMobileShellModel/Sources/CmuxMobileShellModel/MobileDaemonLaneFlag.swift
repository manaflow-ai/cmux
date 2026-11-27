public import Foundation

/// Whether the phone may reach a cmux-next Mac's cmux-tui daemon over an irx
/// `daemon` lane (instead of the Mac's mobile.* RPC dialect).
///
/// Off by default everywhere and never on in the App Store build: env
/// `CMUX_DAEMON_LANE=1` (launch argument or scheme) or defaults key
/// `cmux.debug.daemonLane` turns it on for dev, beta and internal builds.
/// The Mac must also advertise ``capability``.
public struct MobileDaemonLaneFlag: Sendable {
    public static let capability = "daemon_lane.v1"
    public static let defaultsKey = "cmux.debug.daemonLane"

    private let buildType: MobileBuildType
    private let environment: [String: String]
    private let defaultsValue: Bool?

    public init(buildType: MobileBuildType, environment: [String: String], defaults: UserDefaults) {
        self.buildType = buildType
        self.environment = environment
        defaultsValue = defaults.object(forKey: Self.defaultsKey) == nil ? nil : defaults.bool(forKey: Self.defaultsKey)
    }

    public var isEnabled: Bool {
        guard buildType != .prod, buildType != .demo else { return false }
        if let raw = environment["CMUX_DAEMON_LANE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        return defaultsValue ?? false
    }

    /// Enabled here and advertised by the connected Mac.
    public func isAvailable(hostCapabilities: Set<String>) -> Bool {
        isEnabled && hostCapabilities.contains(Self.capability)
    }
}
