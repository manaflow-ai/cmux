import CmuxExtensionKit
import Darwin

extension CmuxPluginRuntime {
    /// Checks a plugin-tagged `events.stream` request on the socket worker.
    func authorizeSubscription(
        pluginID: String,
        token: String,
        requestedNames: Set<String>,
        peerProcessID: pid_t? = nil
    ) -> CmuxPluginSocketAuthorization {
        guard let peerProcessID else {
            return .denied(Self.pluginIdentityMismatchMessage)
        }
        lock.lock()
        let processAuthorizationSnapshot = processAuthorizations
        lock.unlock()
        guard let resolvedProcess = processAuthorizationResolver.resolve(
            processID: peerProcessID,
            authorizations: processAuthorizationSnapshot
        ), resolvedProcess.authorization == .active(pluginID: pluginID) else {
            return .denied(Self.pluginIdentityMismatchMessage)
        }
        lock.lock()
        defer { lock.unlock() }
        guard processAuthorizations[resolvedProcess.rootProcessID]
                == resolvedProcess.authorization else {
            return .denied(Self.pluginIdentityMismatchMessage)
        }
        guard processIdentityIsCurrentLocked(rootProcessID: resolvedProcess.rootProcessID) else {
            return .denied(Self.pluginIdentityMismatchMessage)
        }
        guard let descriptor = snapshot.plugins.first(where: {
            $0.plugin.manifest.id == pluginID
        }) else {
            return .denied(String(
                localized: "socket.events.pluginAuthorization.unknownPlugin",
                defaultValue: "Unknown plugin."
            ))
        }
        guard descriptor.isEnabled else {
            return .denied(String(
                localized: "socket.events.pluginAuthorization.disabled",
                defaultValue: "The plugin is disabled."
            ))
        }
        guard let expectedToken = sessionTokens[pluginID],
              Self.constantTimeEquals(expectedToken, token) else {
            return .denied(String(
                localized: "socket.events.pluginAuthorization.invalidToken",
                defaultValue: "The plugin session token is invalid."
            ))
        }
        let allowedNames = CmuxPluginSubscriptionPolicy(
            pluginID: pluginID,
            permissions: descriptor.permissions
        ).allowedEventNames
        guard !allowedNames.isEmpty else {
            return .denied(String(
                localized: "socket.events.pluginAuthorization.noApprovedSubscriptions",
                defaultValue: "The plugin has no approved event or action subscriptions."
            ))
        }
        if requestedNames.isEmpty {
            return .allowed(Self.canonicalEventNames(allowedNames))
        }
        let canonicalRequestedNames = Self.canonicalEventNames(requestedNames)
        let unresolved = requestedNames.filter {
            $0 != CmuxPluginActionInvocation.eventName
                && CmuxExtensionEvent.canonicalName(forWireName: $0) == nil
        }
        guard unresolved.isEmpty else {
            return .denied(Self.eventScopeNotGrantedMessage(unresolved))
        }
        let denied = canonicalRequestedNames.subtracting(
            Self.canonicalEventNames(allowedNames)
        )
        guard denied.isEmpty else {
            return .denied(Self.eventScopeNotGrantedMessage(denied))
        }
        return .allowed(canonicalRequestedNames)
    }

    /// Registers a live stream under the same lock as the token projection.
    /// This closes the authorization-to-subscription race: a disable or grant
    /// change either wins first and rejects registration, or wins second and
    /// closes the newly registered stream.
    func registerSubscription(
        _ subscription: CmuxEventSubscription,
        pluginID: String,
        token: String,
        peerProcessID: pid_t?
    ) -> Bool {
        guard let peerProcessID else { return false }
        lock.lock()
        let processAuthorizationSnapshot = processAuthorizations
        lock.unlock()
        guard let resolvedProcess = processAuthorizationResolver.resolve(
            processID: peerProcessID,
            authorizations: processAuthorizationSnapshot
        ), resolvedProcess.authorization == .active(pluginID: pluginID) else {
            return false
        }
        lock.lock()
        guard processAuthorizations[resolvedProcess.rootProcessID]
                == resolvedProcess.authorization,
              processIdentityIsCurrentLocked(rootProcessID: resolvedProcess.rootProcessID),
              let expectedToken = sessionTokens[pluginID],
              Self.constantTimeEquals(expectedToken, token),
              snapshot.plugins.contains(where: {
                  $0.plugin.manifest.id == pluginID && $0.isEnabled
              }) else {
            lock.unlock()
            return false
        }
        subscriptionsByPluginID[pluginID, default: [:]][subscription.id] = subscription
        let receivesActions = subscription.names.contains(CmuxPluginActionInvocation.eventName)
        let becameActionReady: Bool
        if receivesActions {
            let wasReady = actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false
            actionSubscriptionIDsByPluginID[pluginID, default: []].insert(subscription.id)
            becameActionReady = !wasReady
        } else {
            becameActionReady = false
        }
        lock.unlock()
        if becameActionReady {
            actionReadinessDidChange()
        }
        return true
    }

    /// Removes a completed stream from the revocation registry.
    func unregisterSubscription(_ subscription: CmuxEventSubscription, pluginID: String) {
        lock.lock()
        subscriptionsByPluginID[pluginID]?[subscription.id] = nil
        if subscriptionsByPluginID[pluginID]?.isEmpty == true {
            subscriptionsByPluginID[pluginID] = nil
        }
        let wasActionReady = actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false
        actionSubscriptionIDsByPluginID[pluginID]?.remove(subscription.id)
        if actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == true {
            actionSubscriptionIDsByPluginID[pluginID] = nil
        }
        let becameActionUnavailable = wasActionReady
            && actionSubscriptionIDsByPluginID[pluginID] == nil
        lock.unlock()
        if becameActionUnavailable {
            actionReadinessDidChange()
        }
    }

    /// Synchronous generation check used immediately before socket writes.
    func subscriptionIsCurrent(pluginID: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedToken = sessionTokens[pluginID] else { return false }
        return Self.constantTimeEquals(expectedToken, token)
    }

    private static func canonicalEventNames(_ names: Set<String>) -> Set<String> {
        Set(names.compactMap { name in
            if name == CmuxPluginActionInvocation.eventName { return name }
            return CmuxExtensionEvent.canonicalName(forWireName: name)
        })
    }

    private static var pluginIdentityMismatchMessage: String {
        String(
            localized: "socket.events.pluginAuthorization.identityMismatch",
            defaultValue: "Plugin identity does not match a supervised process."
        )
    }

    private static func eventScopeNotGrantedMessage(_ names: Set<String>) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "socket.events.pluginAuthorization.eventScopeNotGranted",
                defaultValue: "Event scope not granted: %@"
            ),
            names.sorted().joined(separator: ", ")
        )
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
