import CmuxExtensionKit
import Foundation

extension CmuxPluginRuntime {
    /// Requests a coalesced manifest rescan after filesystem or settings changes.
    func reload() {
        lock.lock()
        let continuation = pluginReloadContinuation
        lock.unlock()
        if let continuation {
            // The bufferingNewest(1) stream keeps a continuous filesystem storm
            // at one in-flight scan plus one latest pending request.
            continuation.yield(())
            return
        }
        _ = enqueueRegistryUpdate { registry in
            await registry.reload()
        }
    }

    /// Performs one serialized reload for the bounded request stream.
    func performPluginReload() async {
        let task = enqueueRegistryUpdate { registry in
            await registry.reload()
        }
        await task.value
    }

    /// Approves all declarations for a plugin after an explicit Settings action.
    func approveAll(pluginID: String) {
        _ = enqueueRegistryUpdate(errorPluginID: pluginID) { registry in
            try await registry.approveAll(pluginID: pluginID)
        }
    }

    /// Enables or disables a plugin after a Settings action.
    func setEnabled(_ enabled: Bool, pluginID: String) {
        _ = enqueueRegistryUpdate(errorPluginID: pluginID) { registry in
            try await registry.setEnabled(enabled, pluginID: pluginID)
        }
    }

    /// Orders registry mutations by request time. Package actors remain the
    /// source of truth, while this chain prevents a slower earlier reload from
    /// overwriting a later Settings decision in the synchronous projection.
    @discardableResult
    private func enqueueRegistryUpdate(
        errorPluginID: String? = nil,
        _ operation: @escaping @Sendable (CmuxPluginRegistry) async throws -> CmuxPluginRegistrySnapshot
    ) -> Task<Void, Never> {
        lock.lock()
        guard !isStopping else {
            lock.unlock()
            return Task {}
        }
        let predecessor = registryUpdateTail
        let registryActor = registry
        let task = Task { [weak self, registryActor] in
            await predecessor?.value
            guard !Task.isCancelled, let self else { return }
            do {
                let next = try await operation(registryActor)
                guard !Task.isCancelled else { return }
                var tokens: [String: String] = [:]
                for descriptor in next.plugins where descriptor.isEnabled {
                    if let token = try? await registryActor.sessionToken(
                        pluginID: descriptor.plugin.manifest.id
                    ) {
                        tokens[descriptor.plugin.manifest.id] = token
                    }
                }
                guard !Task.isCancelled else { return }
                self.replace(snapshot: next, tokens: tokens)
                if let errorPluginID {
                    self.recordPluginError(nil, for: errorPluginID)
                }
            } catch {
                guard !Task.isCancelled, let errorPluginID else { return }
                self.recordPluginError(
                    String(
                        localized: "settings.plugins.error.permissionUpdate",
                        defaultValue: "The plugin permission change could not be saved."
                    ),
                    for: errorPluginID
                )
            }
        }
        registryUpdateTail = task
        lock.unlock()
        return task
    }
}
