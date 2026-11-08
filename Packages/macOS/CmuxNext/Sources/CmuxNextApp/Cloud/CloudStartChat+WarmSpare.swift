import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// Leo, Cloud V0 item 1: "harness login attached in advance". When the person shows intent (the composer picks Cloud,
/// or the app comes to the front signed in), Rust warms their paused spare (`cmux link start-chat warm-spare`, which also
/// decides how often) and this copies their login onto it with the start's own owner check and transfer. The chat that
/// claims the spare then finds "machine login cached".
extension CloudStartChat {
    /// The warm's harness login line: the probe ties a later "machine login cached" to it (cmuxterm-hq#7725).
    static let warmSpareStep = "cloud warm spare"
    @MainActor private static var warming: Task<Void, Never>?

    /// Warms the spare and returns once the platform answered; the login copy goes on after. One warm at a time.
    @MainActor static func warmSpare(_ services: AppServices) async {
        if let warming { return await warming.value }
        let task = Task { @MainActor in await warmOnce(services) }
        warming = task
        await task.value
        warming = nil
    }

    @MainActor private static func warmOnce(_ services: AppServices) async {
        let cloud = services.cloud
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let userID = cloud.auth.user?.id,
              let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL(),
              let token = try? await cloud.auth.tokens().access else { return }
        var request: [String: Any] = ["platform": platform.absoluteString, "account": userID]
        if let team = try? await cloud.reservationTeam() { request["team"] = team }
        guard let payload = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
              let answer = try? await CloudMoveCLI(binary: binary).startChatWarmSpare(request: String(decoding: payload, as: UTF8.self), access: token),
              let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any], reply["fresh"] as? Bool == true,
              let machineID = reply["machine"] as? String else { return }
        let owns = reply["vm_kind"] as? String == "owner" // the platform's owner answer for this machine, as callerOwnsVM's
        // task-owner: one login copy per fresh warm (Rust answers fresh at most once per warm window); it never prompts.
        Task { @MainActor in
            _ = await CloudStartChat(services: services).passHarnessLogin(harness: "claude", target: .init(machineID: machineID, title: machineID,
                step: warmSpareStep, callerOwns: { owns }, record: { _ in }), codexPrompt: false, ask: .init(headless: true))
        }
    }
}
