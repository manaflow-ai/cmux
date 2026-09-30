internal import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Re-evaluated as the paired-Mac list or any connection identity changes.
    public var taskModelPrefetchTargets: [MobileTaskModelPrefetchTarget] {
        guard isSignedIn else { return [] }
        return taskComposerPairedMacs.map { mac in
            let identity = taskModelConnectionIdentity(
                macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag
            )
            return MobileTaskModelPrefetchTarget(
                macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag,
                connectionIdentity: identity
            )
        }
    }

    /// Warms every provider on every paired Mac without changing foreground focus.
    public func prefetchTaskModels(for targets: [MobileTaskModelPrefetchTarget]) async {
        let requests = targets.flatMap { target in
            MobileTaskAgentProvider.allCases.map { (target, $0) }
        }
        await withTaskGroup(of: Void.self) { group in
            for (target, provider) in requests {
                group.addTask {
                    await self.prefetchTaskModel(provider: provider, target: target)
                }
            }
            for await _ in group { }
        }
    }

    @MainActor
    private func prefetchTaskModel(
        provider: MobileTaskAgentProvider,
        target: MobileTaskModelPrefetchTarget
    ) async {
        guard !Task.isCancelled,
              isSignedIn,
              taskModelConnectionIdentity(
                  macDeviceID: target.macDeviceID, instanceTag: target.instanceTag
              ) == target.connectionIdentity else { return }
        _ = await refreshTaskModels(
            provider: provider, macDeviceID: target.macDeviceID,
            instanceTag: target.instanceTag, maximumCacheAge: 300
        )
    }
}
