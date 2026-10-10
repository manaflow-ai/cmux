import Foundation
public import Observation

/// Default browser and default terminal steps: which claims cmux holds,
/// and making cmux the handler (macOS confirms the browser change itself).
@MainActor
@Observable
public final class DefaultAppsStepModel {
    public private(set) var claimed: Set<DefaultHandlerClaim> = []
    /// Claims being requested now (a system prompt may be showing).
    public private(set) var pending: Set<DefaultHandlerClaim> = []
    /// The browser that opens web links now, by display name.
    public private(set) var currentBrowserName: String?
    /// The last refusal or failure, per claim.
    public private(set) var errors: [DefaultHandlerClaim: String] = [:]
    @ObservationIgnored private let services: any OnboardingServices

    init(services: any OnboardingServices) {
        self.services = services
    }

    public func refresh() {
        let registry = services.defaultApps
        claimed = Set(DefaultHandlerClaim.allCases.filter { registry.isClaimed($0) })
        currentBrowserName = registry.handler(forScheme: "https").map { url in
            FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    public func isClaimed(_ claim: DefaultHandlerClaim) -> Bool { claimed.contains(claim) }

    public func request(_ claim: DefaultHandlerClaim) {
        guard !pending.contains(claim) else { return }
        pending.insert(claim)
        errors[claim] = nil
        let registry = services.defaultApps
        Task { [weak self] in
            do {
                try await registry.claim(claim)
            } catch {
                self?.errors[claim] = (error as? CocoaError)?.code == .userCancelled ? nil : error.localizedDescription
            }
            self?.pending.remove(claim)
            self?.refresh()
        }
    }
}
