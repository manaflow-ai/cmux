import Foundation
import CmuxSettings

struct MobileHostIrohFlag: Sendable, Equatable {
    static let envKey = "CMUX_MOBILE_IROH_TRANSPORT"
    static let catalogKey = SettingCatalog().mobile.iOSPairingIrohTransport
    static let defaultsKey = catalogKey.userDefaultsKey

    let isEnabled: Bool

    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = Self.isDebugBuild
    ) -> MobileHostIrohFlag {
        func parseBool(_ raw: String) -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        }

        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return MobileHostIrohFlag(isEnabled: parseBool(raw))
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return MobileHostIrohFlag(isEnabled: defaults.bool(forKey: defaultsKey))
        }
        return MobileHostIrohFlag(isEnabled: catalogKey.defaultValue)
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
