import CMUXMobileCore
import Foundation

struct MobilePairingManualHostAdvertisability: Sendable {
    func isAdvertisable(_ rawHost: String) -> Bool {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        guard let host = CmxManualHost(trimmed) else {
            return false
        }
        return !CmxLoopbackHost().matches(host.rawValue)
    }
}
