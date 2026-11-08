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

    /// Warms the spare and copies the login onto it; returns when both ended. One warm at a time. Rust picks the team (the
    /// install token's, as the reserve sends) and the target; the copy goes only there, while account and teams are the warm's.
    @MainActor static func warmSpare(_ services: AppServices) async {
        let cloud = services.cloud
        if let running = cloud.spareWarm { return await running.value }
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let userID = cloud.auth.user?.id,
              let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        let teamID = cloud.auth.teamID
        // task-owner: CloudService.spareWarm, one warm at a time; it ends with the CLI's answer and the copy (each has its own timeout).
        let warm = Task { @MainActor in
            guard let token = try? await cloud.auth.tokens().access, let install = try? await cloud.installIdentity.installToken(),
                  cloud.auth.user?.id == userID, cloud.auth.teamID == teamID, let copy = await CloudMoveCLI(binary: binary)
                    .startChatWarmSpare(platform: platform, account: userID, access: token, install: install) else { return }
            let still = { @MainActor @Sendable in try await copy.copyAllowed(account: cloud.auth.user?.id, team: cloud.reservationTeam()) && cloud.auth.teamID == teamID }
            // The copy is part of the tracked warm: a reserve or a chat start that waits on the warm finds the login there.
            _ = await CloudStartChat(services: services).passHarnessLogin(harness: "claude", target: .init(machineID: copy.machineID,
                title: copy.machineID, step: warmSpareStep, ownerOnly: true, callerOwns: still, record: { _ in }),
                codexPrompt: false, ask: .init(headless: true))
        }
        cloud.spareWarm = warm
        await warm.value
        cloud.spareWarm = nil
    }
}
