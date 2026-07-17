internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

/// The data the launch composer needs before offering a launch: the coding
/// agents the connected Mac can run and the working directories that make
/// sense for a new agent workspace.
public struct MobileAgentLaunchOptions: Sendable, Equatable {
    /// A coding agent the Mac knows how to launch with a prompt.
    public struct Agent: Sendable, Equatable, Identifiable {
        /// Stable agent identifier (`claude`, `codex`).
        public let id: String
        /// User-facing agent name reported by the Mac.
        public let name: String
        /// Whether the agent's executable resolves on the Mac right now.
        public let installed: Bool

        public init(id: String, name: String, installed: Bool) {
            self.id = id
            self.name = name
            self.installed = installed
        }
    }

    /// Launchable agents in the Mac's preferred order.
    public let agents: [Agent]
    /// Suggested working directories, most relevant first.
    public let directoryPaths: [String]
    /// The directory a plain workspace create would inherit, if any.
    public let defaultDirectory: String?

    public init(agents: [Agent], directoryPaths: [String], defaultDirectory: String?) {
        self.agents = agents
        self.directoryPaths = directoryPaths
        self.defaultDirectory = defaultDirectory
    }
}

extension MobileShellComposite {
    static let workspaceLaunchAgentCapability = "workspace.launch_agent.v1"

    /// Whether the connected Mac supports the prompt-compose agent launch
    /// (`mobile.workspace.launch_agent`).
    public var supportsAgentLaunch: Bool {
        supportedHostCapabilities.contains(Self.workspaceLaunchAgentCapability)
            && allowsMacScopedWorkspaceMutations
    }

    /// Fetches launch options from the connected Mac. Options are advisory:
    /// `nil` (offline, old Mac, transient failure) leaves the composer on its
    /// defaults rather than blocking composition.
    public func fetchAgentLaunchOptions() async -> MobileAgentLaunchOptions? {
        guard let client = remoteClient else { return nil }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.agent.launch_options", params: [:])
            )
            let response = try MobileAgentLaunchOptionsResponse.decode(data)
            return MobileAgentLaunchOptions(
                agents: response.agents.map {
                    MobileAgentLaunchOptions.Agent(id: $0.id, name: $0.name, installed: $0.installed)
                },
                directoryPaths: response.directories.map(\.path),
                defaultDirectory: response.defaultDirectory
            )
        } catch {
            return nil
        }
    }

    /// Creates a workspace on the connected Mac running `agentID` on `prompt`,
    /// then selects it so the shell navigates straight into the live terminal.
    /// Mirrors `createRemoteWorkspace`'s apply/select path so launch and plain
    /// create stay one behavior.
    public func launchAgentWorkspace(
        prompt: String,
        agentID: String?,
        workingDirectory: String?
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard let client = remoteClient else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        guard supportsAgentLaunch else {
            return .failure(.unsupported(hostDisplayName: connectedHostName))
        }
        let generation = connectionGeneration
        do {
            var params: [String: Any] = ["prompt": prompt]
            if let agentID, !agentID.isEmpty {
                params["agent"] = agentID
            }
            if let workingDirectory, !workingDirectory.isEmpty {
                params["working_directory"] = workingDirectory
            }
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.workspace.launch_agent", params: params)
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation), !Task.isCancelled else {
                return .success(())
            }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            let createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            if let createdWorkspace {
                setSelectedWorkspaceID(
                    rowWorkspaceID(
                        forRemoteWorkspaceID: createdWorkspace,
                        macDeviceID: foregroundMacDeviceID
                    ) ?? createdWorkspace
                )
            }
            syncSelectedTerminalForWorkspace()
            if createdWorkspace != nil {
                // The user launched an agent to watch it work, not to type;
                // keep the keyboard down on first attach like plain create.
                suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
            }
            return .success(())
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return .success(()) }
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
            }
            markMacConnectionUnavailableIfNeeded(after: error)
            return .failure(workspaceMutationFailure(error, hostDisplayName: connectedHostName))
        }
    }
}
