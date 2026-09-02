public import Foundation

/// Protocol-17 adaptation for Herdr's newline-delimited JSON socket API.
///
/// Checked against Herdr's published schema shapes for `ping`, `session.snapshot`,
/// and `events.subscribe` (see `herdr api schema --json`). Unknown JSON fields are
/// tolerated; missing required fields are errors.
///
/// ## Provider instance identity gap
///
/// Protocol 17 `ping` does **not** return a durable server-lifetime `instance_id`.
/// Until Herdr advertises one, cmux assigns a fresh
/// ``NestedProviderInstanceID/randomConnectionGeneration()`` per successful
/// connection and must not treat reconnects as the same mutation authority.
public struct HerdrProtocol17Compatibility: Sendable {
    /// Tested Herdr protocol number for this adapter profile.
    public static let supportedProtocolNumber = 17

    /// Semantic capabilities advertised for a validated protocol-17 server.
    ///
    /// Protocol 17 exposes typed `*.focus` methods (`workspace.focus`,
    /// `tab.focus`, `pane.focus`, `agent.focus`), so ``topologyFocusV1`` is
    /// included. Rename / input / split remain deferred until later PRs.
    public static let readCapabilities = NestedCapabilitySet(
        capabilities: [
            .topologySnapshotV1,
            .topologyEventsV1,
            .topologyFocusV1,
        ]
    )

    /// Capabilities required to copy ``RemoteTmuxWindowMirror`` for Herdr (PR7).
    public static let mirrorCapabilities = NestedCapabilitySet(
        capabilities: [
            .topologySnapshotV1,
            .topologyEventsV1,
            .topologyFocusV1,
            .paneInputV1,
            .paneSplitV1,
            .paneResizeV1,
            .paneCloseV1,
            .paneReadV1,
        ]
    )

    /// Default topology event subscriptions for the read-only adapter.
    public static let defaultSubscriptions: [[String: String]] = [
        ["type": "workspace.created"],
        ["type": "workspace.updated"],
        ["type": "workspace.renamed"],
        ["type": "workspace.moved"],
        ["type": "workspace.reordered"],
        ["type": "workspace.closed"],
        ["type": "workspace.focused"],
        ["type": "tab.created"],
        ["type": "tab.closed"],
        ["type": "tab.focused"],
        ["type": "tab.renamed"],
        ["type": "tab.moved"],
        ["type": "pane.created"],
        ["type": "pane.closed"],
        ["type": "pane.updated"],
        ["type": "pane.focused"],
        ["type": "pane.moved"],
        ["type": "pane.exited"],
        ["type": "pane.agent_detected"],
    ]

    /// Default subscriptions plus parameterized `pane.agent_status_changed` for each pane.
    public static func subscriptions(forPaneIDs paneIDs: [String]) -> [[String: String]] {
        var subscriptions = defaultSubscriptions
        var seen = Set<String>()
        for paneID in paneIDs {
            let trimmed = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            subscriptions.append([
                "type": "pane.agent_status_changed",
                "pane_id": trimmed,
            ])
        }
        return subscriptions
    }

    public init() {}

    /// Validates a decoded `ping` / `pong` result and builds handshake metadata.
    public func makeHandshake(
        from pong: HerdrWirePong,
        providerInstanceID: NestedProviderInstanceID,
        instanceIdentityIsDurable: Bool
    ) throws -> NestedProviderHandshake {
        guard pong.protocolNumber == Self.supportedProtocolNumber else {
            throw NestedTopologyProviderError.unsupportedProtocol(pong.protocolNumber)
        }
        let version = pong.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("result.version")
        }
        return NestedProviderHandshake(
            providerKind: .herdr,
            providerInstanceID: providerInstanceID,
            version: version,
            protocolNumber: pong.protocolNumber,
            capabilities: Self.readCapabilities,
            instanceIdentityIsDurable: instanceIdentityIsDurable
        )
    }

    /// Maps a protocol-17 `session.snapshot` payload into the provider-neutral model.
    public func makeSnapshot(
        from wire: HerdrWireSessionSnapshot,
        handshake: NestedProviderHandshake,
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        limits: NestedTopologyLimits
    ) throws -> NestedTopologySnapshot {
        let instance = handshake.providerInstanceID
        var workspaces: [NestedWorkspaceNode] = []
        workspaces.reserveCapacity(wire.workspaces.count)
        for (index, workspace) in wire.workspaces.enumerated() {
            let rawID = workspace.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("workspaces[].workspace_id")
            }
            workspaces.append(
                NestedWorkspaceNode(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .workspace,
                        rawID: rawID
                    ),
                    displayTitle: Self.displayTitle(workspace.label, fallback: rawID),
                    orderIndex: max(0, max(workspace.number - 1, index))
                )
            )
        }

        var tabs: [NestedTabNode] = []
        tabs.reserveCapacity(wire.tabs.count)
        for (index, tab) in wire.tabs.enumerated() {
            let rawID = tab.tabID.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceRawID = tab.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("tabs[].tab_id")
            }
            guard !workspaceRawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("tabs[].workspace_id")
            }
            tabs.append(
                NestedTabNode(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .tab,
                        rawID: rawID
                    ),
                    workspaceID: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .workspace,
                        rawID: workspaceRawID
                    ),
                    displayTitle: Self.displayTitle(tab.label, fallback: rawID),
                    orderIndex: max(0, max(tab.number - 1, index))
                )
            )
        }

        var panes: [NestedPaneNode] = []
        panes.reserveCapacity(wire.panes.count)
        var paneOrderByTab: [String: Int] = [:]
        for pane in wire.panes {
            let rawID = pane.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
            let tabRawID = pane.tabID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("panes[].pane_id")
            }
            guard !tabRawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("panes[].tab_id")
            }
            let order = paneOrderByTab[tabRawID, default: 0]
            paneOrderByTab[tabRawID] = order + 1
            panes.append(
                NestedPaneNode(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .pane,
                        rawID: rawID
                    ),
                    tabID: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .tab,
                        rawID: tabRawID
                    ),
                    displayTitle: Self.paneDisplayTitle(pane),
                    orderIndex: order
                )
            )
        }

        var agents: [NestedAgentNode] = []
        agents.reserveCapacity(wire.agents.count)
        var agentOrderByPane: [String: Int] = [:]
        for agent in wire.agents {
            let paneRawID = agent.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneRawID.isEmpty else {
                throw NestedTopologyProviderError.missingRequiredField("agents[].pane_id")
            }
            // Herdr agents are addressed by pane id; use the pane id as the opaque agent raw id.
            let order = agentOrderByPane[paneRawID, default: 0]
            agentOrderByPane[paneRawID] = order + 1
            let rawStatus = agent.agentStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let status = NestedAgentStatus.normalized(from: rawStatus) else {
                throw NestedTopologyProviderError.missingRequiredField("agents[].agent_status")
            }
            agents.append(
                NestedAgentNode(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .agent,
                        rawID: paneRawID
                    ),
                    paneID: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .pane,
                        rawID: paneRawID
                    ),
                    displayTitle: Self.agentDisplayTitle(agent, fallback: paneRawID),
                    status: status,
                    providerRawStatus: rawStatus,
                    orderIndex: order
                )
            )
        }

        let focus = NestedFocus(
            workspaceID: wire.focusedWorkspaceID.flatMap { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return NestedNodeID(
                    providerKind: .herdr,
                    providerInstanceID: instance,
                    kind: .workspace,
                    rawID: trimmed
                )
            },
            tabID: wire.focusedTabID.flatMap { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return NestedNodeID(
                    providerKind: .herdr,
                    providerInstanceID: instance,
                    kind: .tab,
                    rawID: trimmed
                )
            },
            paneID: wire.focusedPaneID.flatMap { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return NestedNodeID(
                    providerKind: .herdr,
                    providerInstanceID: instance,
                    kind: .pane,
                    rawID: trimmed
                )
            },
            agentID: nil
        )

        let snapshot = NestedTopologySnapshot(
            attachmentID: attachmentID,
            hostStableSurfaceID: hostStableSurfaceID,
            provider: handshake,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            focus: focus
        )
        var reducer = NestedTopologyReducer(
            providerKind: .herdr,
            providerInstanceID: instance,
            limits: limits
        )
        _ = try reducer.apply(.replaceSnapshot(snapshot))
        guard let validated = reducer.snapshot else {
            throw NestedTopologyProviderError.missingRequiredField("snapshot")
        }
        return validated
    }

    /// Maps one protocol-17 event envelope into zero or more domain events.
    ///
    /// Unknown event kinds are ignored (empty array). Malformed known events throw.
    public func mapEvent(
        _ envelope: HerdrWireEventEnvelope,
        handshake: NestedProviderHandshake
    ) throws -> [NestedTopologyEvent] {
        let instance = handshake.providerInstanceID
        switch envelope.event {
        case "workspace_created", "workspace_updated":
            let workspace = try envelope.decodeWorkspace()
            return [.workspaceUpserted(try makeWorkspaceNode(workspace, instance: instance))]
        case "workspace_renamed":
            let workspaceID = try envelope.requireString("workspace_id")
            let label = try envelope.requireString("label")
            return [
                .titleUpdated(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .workspace,
                        rawID: workspaceID
                    ),
                    displayTitle: Self.displayTitle(label, fallback: workspaceID)
                ),
            ]
        case "workspace_closed":
            let workspaceID = try envelope.requireString("workspace_id")
            return [
                .workspaceClosed(
                    NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .workspace,
                        rawID: workspaceID
                    )
                ),
            ]
        case "workspace_focused":
            let workspaceID = try envelope.requireString("workspace_id")
            return [
                .focusChanged(
                    NestedFocus(
                        workspaceID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .workspace,
                            rawID: workspaceID
                        )
                    )
                ),
            ]
        case "workspace_moved", "workspace_reordered":
            let workspaces = try envelope.decodeWorkspaceList()
            return try workspaces.enumerated().map { index, workspace in
                var node = try makeWorkspaceNode(workspace, instance: instance)
                node = NestedWorkspaceNode(
                    id: node.id,
                    displayTitle: node.displayTitle,
                    orderIndex: index
                )
                return .workspaceUpserted(node)
            }
        case "tab_created":
            let tab = try envelope.decodeTab()
            return [.tabUpserted(try makeTabNode(tab, instance: instance))]
        case "tab_renamed":
            let tabID = try envelope.requireString("tab_id")
            let label = try envelope.requireString("label")
            return [
                .titleUpdated(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .tab,
                        rawID: tabID
                    ),
                    displayTitle: Self.displayTitle(label, fallback: tabID)
                ),
            ]
        case "tab_closed":
            let tabID = try envelope.requireString("tab_id")
            return [
                .tabClosed(
                    NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .tab,
                        rawID: tabID
                    )
                ),
            ]
        case "tab_focused":
            let tabID = try envelope.requireString("tab_id")
            let workspaceID = try envelope.requireString("workspace_id")
            return [
                .focusChanged(
                    NestedFocus(
                        workspaceID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .workspace,
                            rawID: workspaceID
                        ),
                        tabID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .tab,
                            rawID: tabID
                        )
                    )
                ),
            ]
        case "tab_moved":
            let tabs = try envelope.decodeTabList()
            return try tabs.enumerated().map { index, tab in
                var node = try makeTabNode(tab, instance: instance)
                node = NestedTabNode(
                    id: node.id,
                    workspaceID: node.workspaceID,
                    displayTitle: node.displayTitle,
                    orderIndex: index
                )
                return .tabUpserted(node)
            }
        case "pane_created", "pane_updated":
            let pane = try envelope.decodePane()
            return try mapPaneAndOptionalAgent(pane, instance: instance)
        case "pane_closed", "pane_exited":
            let paneID = try envelope.requireString("pane_id")
            let paneNodeID = NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .pane,
                rawID: paneID
            )
            return [
                .agentClosed(
                    NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .agent,
                        rawID: paneID
                    )
                ),
                .paneClosed(paneNodeID),
            ]
        case "pane_focused":
            let paneID = try envelope.requireString("pane_id")
            let workspaceID = try envelope.requireString("workspace_id")
            return [
                .focusChanged(
                    NestedFocus(
                        workspaceID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .workspace,
                            rawID: workspaceID
                        ),
                        paneID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .pane,
                            rawID: paneID
                        )
                    )
                ),
            ]
        case "pane_moved":
            let previousPaneID = try envelope.requireString("previous_pane_id")
            let pane = try envelope.decodePane()
            var events: [NestedTopologyEvent] = [
                .paneClosed(
                    NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .pane,
                        rawID: previousPaneID
                    )
                ),
                .agentClosed(
                    NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .agent,
                        rawID: previousPaneID
                    )
                ),
            ]
            events.append(contentsOf: try mapPaneAndOptionalAgent(pane, instance: instance))
            if let closedTabID = envelope.optionalString("closed_tab_id") {
                events.append(
                    .tabClosed(
                        NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .tab,
                            rawID: closedTabID
                        )
                    )
                )
            }
            if let closedWorkspaceID = envelope.optionalString("closed_workspace_id") {
                events.append(
                    .workspaceClosed(
                        NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .workspace,
                            rawID: closedWorkspaceID
                        )
                    )
                )
            }
            return events
        case "pane_agent_detected":
            let paneID = try envelope.requireString("pane_id")
            if envelope.boolValue("released") == true {
                return [
                    .agentClosed(
                        NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .agent,
                            rawID: paneID
                        )
                    ),
                ]
            }
            let rawStatus = envelope.optionalString("final_status") ?? "unknown"
            let status = NestedAgentStatus.normalized(from: rawStatus) ?? .unknown
            let title = envelope.optionalString("agent") ?? paneID
            return [
                .agentUpserted(
                    NestedAgentNode(
                        id: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .agent,
                            rawID: paneID
                        ),
                        paneID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .pane,
                            rawID: paneID
                        ),
                        displayTitle: Self.displayTitle(title, fallback: paneID),
                        status: status,
                        providerRawStatus: rawStatus,
                        orderIndex: 0
                    )
                ),
            ]
        case "pane.agent_status_changed":
            // Subscription-scoped agent status events use dotted event names.
            let paneID = try envelope.requireString("pane_id")
            let rawStatus = try envelope.requireString("agent_status")
            guard let status = NestedAgentStatus.normalized(from: rawStatus) else {
                throw NestedTopologyProviderError.missingRequiredField("data.agent_status")
            }
            let title = envelope.optionalString("display_agent")
                ?? envelope.optionalString("agent")
                ?? envelope.optionalString("title")
                ?? paneID
            return [
                .agentUpserted(
                    NestedAgentNode(
                        id: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .agent,
                            rawID: paneID
                        ),
                        paneID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .pane,
                            rawID: paneID
                        ),
                        displayTitle: Self.displayTitle(title, fallback: paneID),
                        status: status,
                        providerRawStatus: rawStatus,
                        orderIndex: 0
                    )
                ),
                .agentStatusUpdated(
                    id: NestedNodeID(
                        providerKind: .herdr,
                        providerInstanceID: instance,
                        kind: .agent,
                        rawID: paneID
                    ),
                    status: status,
                    providerRawStatus: rawStatus
                ),
            ]
        default:
            return []
        }
    }

    /// Decodes a success/error response object and validates the correlation id.
    public func decodeResponseLine(
        _ line: String,
        expectedRequestID: HerdrJSONRPCRequestID
    ) throws -> HerdrWireResponse {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        let response: HerdrWireResponse
        do {
            response = try decoder.decode(HerdrWireResponse.self, from: data)
        } catch {
            throw NestedTopologyProviderError.malformedJSON(String(describing: error))
        }
        guard response.id == expectedRequestID.rawValue else {
            throw NestedTopologyProviderError.responseIDMismatch(
                expected: expectedRequestID.rawValue,
                actual: response.id
            )
        }
        if let error = response.error {
            throw NestedTopologyProviderError.providerError(code: error.code, message: error.message)
        }
        guard response.result != nil else {
            throw NestedTopologyProviderError.missingRequiredField("result")
        }
        return response
    }

    /// Decodes a pushed event line (no request id).
    public func decodeEventLine(_ line: String) throws -> HerdrWireEventEnvelope {
        let data = Data(line.utf8)
        do {
            return try JSONDecoder().decode(HerdrWireEventEnvelope.self, from: data)
        } catch {
            throw NestedTopologyProviderError.malformedJSON(String(describing: error))
        }
    }

    // MARK: - Private helpers

    private func makeWorkspaceNode(
        _ workspace: HerdrWireWorkspace,
        instance: NestedProviderInstanceID
    ) throws -> NestedWorkspaceNode {
        let rawID = workspace.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("workspace.workspace_id")
        }
        return NestedWorkspaceNode(
            id: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .workspace,
                rawID: rawID
            ),
            displayTitle: Self.displayTitle(workspace.label, fallback: rawID),
            orderIndex: max(0, workspace.number - 1)
        )
    }

    private func makeTabNode(
        _ tab: HerdrWireTab,
        instance: NestedProviderInstanceID
    ) throws -> NestedTabNode {
        let rawID = tab.tabID.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceRawID = tab.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("tab.tab_id")
        }
        guard !workspaceRawID.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("tab.workspace_id")
        }
        return NestedTabNode(
            id: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .tab,
                rawID: rawID
            ),
            workspaceID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .workspace,
                rawID: workspaceRawID
            ),
            displayTitle: Self.displayTitle(tab.label, fallback: rawID),
            orderIndex: max(0, tab.number - 1)
        )
    }

    private func makePaneNode(
        _ pane: HerdrWirePane,
        instance: NestedProviderInstanceID,
        orderIndex: Int = 0
    ) throws -> NestedPaneNode {
        let rawID = pane.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabRawID = pane.tabID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("pane.pane_id")
        }
        guard !tabRawID.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("pane.tab_id")
        }
        return NestedPaneNode(
            id: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .pane,
                rawID: rawID
            ),
            tabID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: instance,
                kind: .tab,
                rawID: tabRawID
            ),
            displayTitle: Self.paneDisplayTitle(pane),
            orderIndex: orderIndex
        )
    }

    private func mapPaneAndOptionalAgent(
        _ pane: HerdrWirePane,
        instance: NestedProviderInstanceID
    ) throws -> [NestedTopologyEvent] {
        var events: [NestedTopologyEvent] = [.paneUpserted(try makePaneNode(pane, instance: instance))]
        let paneID = pane.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAgent = !(pane.agent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || pane.agentStatus.lowercased() != "unknown"
        if hasAgent {
            let rawStatus = pane.agentStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = NestedAgentStatus.normalized(from: rawStatus) ?? .unknown
            events.append(
                .agentUpserted(
                    NestedAgentNode(
                        id: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .agent,
                            rawID: paneID
                        ),
                        paneID: NestedNodeID(
                            providerKind: .herdr,
                            providerInstanceID: instance,
                            kind: .pane,
                            rawID: paneID
                        ),
                        displayTitle: Self.paneAgentDisplayTitle(pane),
                        status: status,
                        providerRawStatus: rawStatus.isEmpty ? "unknown" : rawStatus,
                        orderIndex: 0
                    )
                )
            )
        }
        return events
    }

    private static func displayTitle(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func paneDisplayTitle(_ pane: HerdrWirePane) -> String {
        displayTitle(
            pane.label
                ?? pane.title
                ?? pane.terminalTitleStripped
                ?? pane.terminalTitle,
            fallback: pane.paneID
        )
    }

    private static func paneAgentDisplayTitle(_ pane: HerdrWirePane) -> String {
        displayTitle(
            pane.displayAgent ?? pane.agent ?? pane.title,
            fallback: pane.paneID
        )
    }

    private static func agentDisplayTitle(_ agent: HerdrWireAgent, fallback: String) -> String {
        displayTitle(
            agent.displayAgent ?? agent.name ?? agent.agent ?? agent.title,
            fallback: fallback
        )
    }
}

// MARK: - Wire DTOs (protocol 17)

/// Decoded Herdr `pong` result.
public struct HerdrWirePong: Hashable, Sendable {
    public var version: String
    public var protocolNumber: Int
    /// Optional future server-lifetime identity. Absent on protocol 17.
    public var instanceID: String?
    public var liveHandoff: Bool?
    public var detachedServerDaemon: Bool?
}

/// Decoded Herdr `session.snapshot` body.
public struct HerdrWireSessionSnapshot: Hashable, Sendable {
    public var version: String
    public var protocolNumber: Int
    public var focusedWorkspaceID: String?
    public var focusedTabID: String?
    public var focusedPaneID: String?
    public var workspaces: [HerdrWireWorkspace]
    public var tabs: [HerdrWireTab]
    public var panes: [HerdrWirePane]
    public var agents: [HerdrWireAgent]
    /// Tab id → layout tree when Herdr publishes `layouts` (PR7 window mirror).
    public var layouts: [String: RemoteHerdrLayoutNode]
}

/// Wire workspace record.
public struct HerdrWireWorkspace: Hashable, Codable, Sendable {
    public var workspaceID: String
    public var number: Int
    public var label: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
    }
}

/// Wire tab record.
public struct HerdrWireTab: Hashable, Codable, Sendable {
    public var tabID: String
    public var workspaceID: String
    public var number: Int
    public var label: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
    }
}

/// Wire pane record.
public struct HerdrWirePane: Hashable, Codable, Sendable {
    public var paneID: String
    public var tabID: String
    public var workspaceID: String
    public var label: String?
    public var title: String?
    public var terminalTitle: String?
    public var terminalTitleStripped: String?
    public var agent: String?
    public var displayAgent: String?
    public var agentStatus: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label
        case title
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agent
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        tabID = try container.decode(String.self, forKey: .tabID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        agentStatus = try container.decodeIfPresent(String.self, forKey: .agentStatus) ?? "unknown"
    }
}

/// Wire agent record.
public struct HerdrWireAgent: Hashable, Codable, Sendable {
    public var paneID: String
    public var tabID: String
    public var workspaceID: String
    public var name: String?
    public var agent: String?
    public var title: String?
    public var displayAgent: String?
    public var agentStatus: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case name
        case agent
        case title
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
    }
}

/// Top-level Herdr response line.
public struct HerdrWireResponse: Sendable {
    public var id: String
    public var result: HerdrWireResult?
    public var error: HerdrWireErrorBody?
}

/// Structured Herdr error body.
public struct HerdrWireErrorBody: Hashable, Codable, Sendable {
    public var code: String
    public var message: String
}

/// Discriminated success result.
public enum HerdrWireResult: Sendable {
    case pong(HerdrWirePong)
    case sessionSnapshot(HerdrWireSessionSnapshot)
    case subscriptionStarted
    case other(type: String, object: [String: AnySendableJSON])
}

/// Minimal JSON value wrapper for unknown result objects.
public enum AnySendableJSON: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnySendableJSON])
    case object([String: AnySendableJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnySendableJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnySendableJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Event envelope pushed after `events.subscribe`.
public struct HerdrWireEventEnvelope: Sendable {
    public var event: String
    public var data: [String: AnySendableJSON]
}

extension HerdrWireResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        error = try container.decodeIfPresent(HerdrWireErrorBody.self, forKey: .error)
        if container.contains(.result) {
            result = try container.decode(HerdrWireResult.self, forKey: .result)
        } else {
            result = nil
        }
    }
}

extension HerdrWireResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        case version
        case protocolNumber = "protocol"
        case instanceID = "instance_id"
        case capabilities
        case snapshot
    }

    enum CapabilityKeys: String, CodingKey {
        case liveHandoff = "live_handoff"
        case detachedServerDaemon = "detached_server_daemon"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pong":
            let version = try container.decode(String.self, forKey: .version)
            let protocolNumber = try container.decode(Int.self, forKey: .protocolNumber)
            let instanceID = try container.decodeIfPresent(String.self, forKey: .instanceID)
            var liveHandoff: Bool?
            var detachedServerDaemon: Bool?
            if container.contains(.capabilities) {
                let caps = try container.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities)
                liveHandoff = try caps.decodeIfPresent(Bool.self, forKey: .liveHandoff)
                detachedServerDaemon = try caps.decodeIfPresent(Bool.self, forKey: .detachedServerDaemon)
            }
            self = .pong(
                HerdrWirePong(
                    version: version,
                    protocolNumber: protocolNumber,
                    instanceID: instanceID,
                    liveHandoff: liveHandoff,
                    detachedServerDaemon: detachedServerDaemon
                )
            )
        case "session_snapshot":
            let snapshot = try container.decode(HerdrWireSessionSnapshot.self, forKey: .snapshot)
            self = .sessionSnapshot(snapshot)
        case "subscription_started":
            self = .subscriptionStarted
        case "ok", "workspace_info", "tab_info", "pane_info", "agent_info":
            // Focus / mutation success shapes. Keep payload fields for pane.read.
            self = .other(type: type, object: herdrPayloadObject(from: decoder))
        default:
            // Tolerate other additive success types without requiring a full schema.
            self = .other(type: type, object: herdrPayloadObject(from: decoder))
        }
    }
}

extension HerdrWireSessionSnapshot: Decodable {
    enum CodingKeys: String, CodingKey {
        case version
        case protocolNumber = "protocol"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces
        case tabs
        case panes
        case agents
        case layouts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        protocolNumber = try container.decode(Int.self, forKey: .protocolNumber)
        focusedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        focusedTabID = try container.decodeIfPresent(String.self, forKey: .focusedTabID)
        focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
        workspaces = try container.decodeIfPresent([HerdrWireWorkspace].self, forKey: .workspaces) ?? []
        tabs = try container.decodeIfPresent([HerdrWireTab].self, forKey: .tabs) ?? []
        panes = try container.decodeIfPresent([HerdrWirePane].self, forKey: .panes) ?? []
        agents = try container.decodeIfPresent([HerdrWireAgent].self, forKey: .agents) ?? []
        layouts = Self.decodeLayouts(container)
    }

    /// Accepts a tab-id map, a `[{tab_id, layout}]` list, or an empty array.
    private static func decodeLayouts(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: RemoteHerdrLayoutNode] {
        if let dict = try? container.decode([String: RemoteHerdrLayoutNode].self, forKey: .layouts) {
            return dict
        }
        if let named = try? container.decode([RemoteHerdrTabLayout].self, forKey: .layouts) {
            var mapped: [String: RemoteHerdrLayoutNode] = [:]
            for item in named where !item.tabID.isEmpty {
                mapped[item.tabID] = item.layout
            }
            return mapped
        }
        return [:]
    }
}

/// Remaining fields of a tagged Herdr result object (everything except `type`).
private func herdrPayloadObject(from decoder: any Decoder) -> [String: AnySendableJSON] {
    guard let json = try? AnySendableJSON(from: decoder), case .object(let object) = json else {
        return [:]
    }
    var payload = object
    payload.removeValue(forKey: "type")
    return payload
}

extension HerdrWireEventEnvelope: Decodable {
    enum CodingKeys: String, CodingKey {
        case event
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        // EventData is a tagged object (`type` + payload fields); keep it as a generic map.
        let raw = try container.decode(AnySendableJSON.self, forKey: .data)
        guard case .object(let object) = raw else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "event data must be an object"
            )
        }
        data = object
    }

    func requireString(_ key: String) throws -> String {
        guard case .string(let value)? = data[key] else {
            throw NestedTopologyProviderError.missingRequiredField("data.\(key)")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NestedTopologyProviderError.missingRequiredField("data.\(key)")
        }
        return trimmed
    }

    func optionalString(_ key: String) -> String? {
        guard case .string(let value)? = data[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func boolValue(_ key: String) -> Bool? {
        guard case .bool(let value)? = data[key] else { return nil }
        return value
    }

    func decodeWorkspace() throws -> HerdrWireWorkspace {
        try decodeObject(HerdrWireWorkspace.self, key: "workspace")
    }

    func decodeTab() throws -> HerdrWireTab {
        try decodeObject(HerdrWireTab.self, key: "tab")
    }

    func decodePane() throws -> HerdrWirePane {
        try decodeObject(HerdrWirePane.self, key: "pane")
    }

    func decodeWorkspaceList() throws -> [HerdrWireWorkspace] {
        try decodeArray(HerdrWireWorkspace.self, key: "workspaces")
    }

    func decodeTabList() throws -> [HerdrWireTab] {
        try decodeArray(HerdrWireTab.self, key: "tabs")
    }

    private func decodeObject<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard case .object(let object)? = data[key] else {
            throw NestedTopologyProviderError.missingRequiredField("data.\(key)")
        }
        let encoded = try JSONEncoder().encode(object)
        do {
            return try JSONDecoder().decode(T.self, from: encoded)
        } catch {
            throw NestedTopologyProviderError.malformedJSON(String(describing: error))
        }
    }

    private func decodeArray<T: Decodable>(_ type: T.Type, key: String) throws -> [T] {
        guard case .array(let array)? = data[key] else {
            throw NestedTopologyProviderError.missingRequiredField("data.\(key)")
        }
        let encoded = try JSONEncoder().encode(array)
        do {
            return try JSONDecoder().decode([T].self, from: encoded)
        } catch {
            throw NestedTopologyProviderError.malformedJSON(String(describing: error))
        }
    }
}
