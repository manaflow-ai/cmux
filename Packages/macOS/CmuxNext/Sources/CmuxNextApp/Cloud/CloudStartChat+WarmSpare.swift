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

    /// Warms the spare and copies the login onto it; returns when both ended. One warm per identity. Rust picks the team (the install
    /// token's) and the owned target, the only ownership check; the copy goes only there, while account and teams are the warm's.
    @MainActor static func warmSpare(_ services: AppServices) async {
        let cloud = services.cloud
        let key = cloud.auth.accountKey ?? ""
        if let running = cloud.spareWarms[key] { return await running.value }
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let userID = cloud.auth.user?.id,
              let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        let teamID = cloud.auth.teamID, cli = CloudMoveCLI(binary: binary)
        // task-owner: CloudService.spareWarms, one warm per identity; it ends with the CLI's answer and the copy (each has its own timeout).
        let warm = Task { @MainActor in
            guard let token = try? await cloud.auth.tokens().access, let install = try? await cloud.installIdentity.installToken(),
                  cloud.auth.user?.id == userID, cloud.auth.teamID == teamID, let copy = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install) else { return }
            let still = { @MainActor @Sendable in try await copy.copyAllowed(account: cloud.auth.user?.id, team: cloud.reservationTeam()) && cloud.auth.teamID == teamID }
            // task-owner: CloudService.spareWarmCopies, by Rust's copy target; it ends with the copy's own timeouts.
            let copying = Task { @MainActor in await CloudStartChat(services: services).passHarnessLogin(harness: "claude", target: .init(machineID: copy.machineID,
                title: copy.machineID, step: warmSpareStep, ownerOnly: true, callerOwns: still, record: { _ in }), codexPrompt: false, ask: .init(headless: true)) }
            cloud.spareWarmCopies[copy.machineID] = copying
            // A copy given up to an account or team switch is not done: Rust answers it again on the next warm.
            if await copying.value == false, (try? await still()) != true { _ = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, abandoned: copy.machineID) }
            cloud.spareWarmCopies[copy.machineID] = nil
        }
        cloud.spareWarms[key] = warm
        await warm.value
        cloud.spareWarms[key] = nil
    }
}
