import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// Leo, Cloud V0 item 1: "harness login attached in advance". On the person's intent (the composer picks Cloud, or the
/// app comes to the front signed in) Rust warms their paused spare (`cmux link start-chat warm-spare`, which also decides
/// how often), and this copies their login onto it with the start's own owner check and transfer. The chat that claims
/// the spare then finds "machine login cached".
extension CloudStartChat {
    /// The warm's harness login line: the probe ties a later "machine login cached" to it (cmuxterm-hq#7725).
    static let warmSpareStep = "cloud warm spare"

    /// Warms the spare and returns once the platform answered; the login copy goes on after. One warm at a time.
    @MainActor static func warmSpare(_ services: AppServices) async {
        let cloud = services.cloud
        if let running = cloud.spareWarm { return await running.value }
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let userID = cloud.auth.user?.id,
              let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        // task-owner: CloudService.spareWarm, one warm at a time; it ends with the CLI's answer (its own timeout).
        let warm = Task { @MainActor in
            guard let token = try? await cloud.auth.tokens().access, let spare = await CloudMoveCLI(binary: binary)
                .startChatWarmSpare(platform: platform, team: try? await cloud.reservationTeam(), account: userID, access: token) else { return }
            // task-owner: one headless login copy per fresh warm (Rust answers fresh at most once per two minutes).
            Task { @MainActor in
                _ = await CloudStartChat(services: services).passHarnessLogin(harness: "claude", target: .init(machineID: spare.machineID,
                    title: spare.machineID, step: warmSpareStep, callerOwns: { spare.callerOwns }, record: { _ in }),
                    codexPrompt: false, ask: .init(headless: true))
            }
        }
        cloud.spareWarm = warm
        await warm.value
        cloud.spareWarm = nil
    }
}
