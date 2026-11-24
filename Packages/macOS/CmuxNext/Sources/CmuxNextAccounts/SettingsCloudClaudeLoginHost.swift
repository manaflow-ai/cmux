package import CmuxNextDaemon
package import Foundation

/// The app supplies its current account, machine registry and Cloud creation flow.
@MainActor
package struct SettingsCloudClaudeLoginHost {
    typealias Machine = SettingsCloudClaudeMachineLink
    let account: @MainActor () -> [String?]?
    let caller: @MainActor () -> String?
    let personal: @MainActor () -> Bool
    let hasLoadedMachines: @MainActor () -> Bool
    let machineIDs: @MainActor () -> Set<String>
    let machine: @MainActor (String) -> Machine?
    let refreshMachines: @MainActor () async -> Bool
    let createMachine: @MainActor (Machine.Check) async throws -> Machine?

    package init(account: @escaping @MainActor () -> [String?]?, caller: @escaping @MainActor () -> String?,
                 personal: @escaping @MainActor () -> Bool, hasLoadedMachines: @escaping @MainActor () -> Bool,
                 machineIDs: @escaping @MainActor () -> Set<String>, machine: @escaping @MainActor (String) -> SettingsCloudClaudeMachineLink?,
                 refreshMachines: @escaping @MainActor () async -> Bool,
                 createMachine: @escaping @MainActor (SettingsCloudClaudeMachineLink.Check) async throws -> SettingsCloudClaudeMachineLink?) {
        self.account = account
        self.caller = caller
        self.personal = personal
        self.hasLoadedMachines = hasLoadedMachines
        self.machineIDs = machineIDs
        self.machine = machine
        self.refreshMachines = refreshMachines
        self.createMachine = createMachine
    }
}

/// The current machine and the operations the Settings sign-in may perform on it.
@MainActor
package struct SettingsCloudClaudeMachineLink {
    package typealias Check = @MainActor () throws -> Void
    package typealias Scope = @MainActor @Sendable () -> Bool

    let candidate: SettingsCloudClaudeLogin.Candidate
    let ownerLink: AgentSessionAttachClient.OwnerLink
    let endpoint: AgentSessionAttachClient.EndpointProvider
    let linkHeld: @MainActor () -> Bool
    let supportsLogin: @MainActor () -> Bool
    let connect: @MainActor (Check) async throws -> Void
    let openCallback: @MainActor (URL, String, @escaping Scope) async -> Bool

    package init(candidate: SettingsCloudClaudeLogin.Candidate, ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                 endpoint: @escaping AgentSessionAttachClient.EndpointProvider, linkHeld: @escaping @MainActor () -> Bool,
                 supportsLogin: @escaping @MainActor () -> Bool, connect: @escaping @MainActor (Check) async throws -> Void,
                 openCallback: @escaping @MainActor (URL, String, @escaping Scope) async -> Bool) {
        self.candidate = candidate
        self.ownerLink = ownerLink
        self.endpoint = endpoint
        self.linkHeld = linkHeld
        self.supportsLogin = supportsLogin
        self.connect = connect
        self.openCallback = openCallback
    }
}
