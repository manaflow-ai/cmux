public import Foundation

public extension BackendProtocolClient {
    /// Idempotently creates or reattaches one caller-identified canonical terminal.
    ///
    /// Repeating the same workspace and surface UUIDs returns the original PTY.
    /// Creation-only fields, including `initialInput`, are ignored on reattach.
    func ensureTerminal(
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        workingDirectory: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendEnsuredTerminalPlacement {
        var parameters: [String: BackendJSONValue] = [
            "workspace_uuid": .string(workspaceID.description),
            "surface_uuid": .string(surfaceID.description),
            "cols": .unsignedInteger(UInt64(columns)),
            "rows": .unsignedInteger(UInt64(rows)),
        ]
        if let workingDirectory { parameters["cwd"] = .string(workingDirectory) }
        if let command { parameters["command"] = .string(command) }
        if let arguments {
            parameters["argv"] = .array(arguments.map(BackendJSONValue.string))
        }
        if !environment.isEmpty {
            parameters["env"] = .array(
                environment.keys.sorted().map { name in
                    .object([
                        "name": .string(name),
                        "value": .string(environment[name] ?? ""),
                    ])
                }
            )
        }
        if let initialInput { parameters["initial_input"] = .string(initialInput) }
        if waitAfterCommand { parameters["wait_after_command"] = .bool(true) }
        return try await call(
            command: "ensure-terminal",
            parameters: parameters,
            as: BackendEnsuredTerminalPlacement.self
        )
    }

    /// Resolves or creates up to 1,024 stable terminals in one canonical
    /// topology and persistence transaction, preserving request order.
    func ensureTerminals(
        _ requests: [BackendEnsureTerminalRequest]
    ) async throws -> [BackendEnsuredTerminalPlacement] {
        guard !requests.isEmpty else { return [] }
        return try await call(
            command: "ensure-terminals",
            parameters: [
                "terminals": .array(requests.map(\.jsonValue)),
            ],
            as: [BackendEnsuredTerminalPlacement].self
        )
    }

    /// Moves one canonical terminal into a workspace without replacing its PTY.
    ///
    /// Repeating a successful move is idempotent and returns `moved == false`.
    func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement {
        return try await call(
            command: "reparent-terminal",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "workspace_uuid": .string(workspaceID.description),
            ],
            as: BackendReparentedTerminalPlacement.self
        )
    }

    /// Configures one visible presentation and returns its exact renderer fences.
    func configureRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        configuration: BackendRendererPresentationConfiguration
    ) async throws -> BackendRendererPresentationReceipt {
        var parameters = configuration.jsonParameters
        parameters["presentation_id"] = .string(id.description)
        parameters["expected_generation"] = .unsignedInteger(expectedGeneration)
        return try await call(
            command: "configure-renderer-presentation",
            parameters: parameters,
            as: BackendRendererPresentationReceipt.self
        )
    }

    /// Detaches renderer state without closing the presentation or canonical PTY.
    func detachRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "detach-renderer-presentation",
            parameters: [
                "presentation_id": .string(id.description),
                "expected_generation": .unsignedInteger(expectedGeneration),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Updates presentation-local IME text without writing it to the PTY.
    func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        preedit: BackendTerminalPreedit?
    ) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "terminal-preedit",
            parameters: [
                "presentation_id": .string(presentationID.description),
                "renderer_generation": .unsignedInteger(rendererGeneration),
                "text": preedit.map { .string($0.text) } ?? .null,
                "selection_start_utf16": .unsignedInteger(UInt64(
                    preedit?.selectionStartUTF16 ?? 0
                )),
                "selection_length_utf16": .unsignedInteger(UInt64(
                    preedit?.selectionLengthUTF16 ?? 0
                )),
                "caret_utf16": .unsignedInteger(UInt64(preedit?.caretUTF16 ?? 0)),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Releases one exact IOSurface pool slot after host GPU consumption.
    func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse {
        try await call(
            command: "release-renderer-frame",
            parameters: release.jsonParameters,
            as: BackendRendererFrameReleaseResponse.self
        )
    }

    /// Returns the worker process census used for diagnostics and restart recovery.
    func rendererWorkers() async throws -> BackendRendererWorkersResponse {
        try await call(command: "renderer-workers", as: BackendRendererWorkersResponse.self)
    }

    /// Creates the first exactly identified terminal in a new canonical workspace.
    func canonicalNewWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String? = nil,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = try launch.validatedJSONParameters()
        parameters.merge(expectation.jsonParameters) { _, new in new }
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        if let name { parameters["name"] = .string(name) }
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-new-workspace",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Creates another exactly identified terminal tab in a stable pane.
    func canonicalNewTerminalTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = try launch.validatedJSONParameters()
        parameters.merge(expectation.jsonParameters) { _, new in new }
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-new-tab",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Materializes one exactly identified terminal in an existing workspace.
    func canonicalMaterializeTerminal(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = try launch.validatedJSONParameters()
        parameters.merge(expectation.jsonParameters) { _, new in new }
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-materialize-terminal",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Replaces one terminal runtime while preserving its stable surface UUID.
    func canonicalRespawnTerminal(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = try launch.validatedJSONParameters()
        parameters.merge(expectation.jsonParameters) { _, new in new }
        parameters["surface_uuid"] = .string(surfaceID.description)
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-respawn-terminal",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Creates a workspace whose first surface is parser-only, with no transient PTY.
    func canonicalNewExternalWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance,
        producerSource: BackendRemoteTmuxProducerSource
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["cols"] = .unsignedInteger(UInt64(columns))
        parameters["rows"] = .unsignedInteger(UInt64(rows))
        parameters["no_reflow"] = .bool(noReflow)
        parameters["provenance"] = provenance.jsonValue
        parameters["producer_source"] = producerSource.jsonValue
        return try await call(
            command: "canonical-new-external-workspace",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Materializes one parser-only terminal with no daemon PTY or child process.
    func canonicalMaterializeExternalTerminal(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["cols"] = .unsignedInteger(UInt64(columns))
        parameters["rows"] = .unsignedInteger(UInt64(rows))
        parameters["no_reflow"] = .bool(noReflow)
        parameters["provenance"] = provenance.jsonValue
        return try await call(
            command: "canonical-materialize-external-terminal",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    func claimExternalTerminal(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendExternalTerminalClaimReceipt {
        try await call(
            command: "claim-external-terminal",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "request_id": .string(requestID.uuidString.lowercased()),
            ],
            as: BackendExternalTerminalClaimReceipt.self
        )
    }

    func resetExternalTerminal(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        seed: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        try await call(
            command: "reset-external-terminal",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "owner_generation": .unsignedInteger(ownerGeneration),
                "request_id": .string(requestID.uuidString.lowercased()),
                "output_generation": .unsignedInteger(outputGeneration),
                "cols": .unsignedInteger(UInt64(columns)),
                "rows": .unsignedInteger(UInt64(rows)),
                "no_reflow": .bool(noReflow),
                "seed": .string(seed.base64EncodedString()),
            ],
            as: BackendExternalTerminalOutputReceipt.self
        )
    }

    func sendExternalTerminalOutput(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        sequence: UInt64,
        data: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        try await call(
            command: "external-terminal-output",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "owner_generation": .unsignedInteger(ownerGeneration),
                "request_id": .string(requestID.uuidString.lowercased()),
                "output_generation": .unsignedInteger(outputGeneration),
                "sequence": .unsignedInteger(sequence),
                "data": .string(data.base64EncodedString()),
            ],
            as: BackendExternalTerminalOutputReceipt.self
        )
    }

    func drainExternalTerminalEgress(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64
    ) async throws -> Data {
        return try await call(
            command: "drain-external-terminal-egress",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "owner_generation": .unsignedInteger(ownerGeneration),
            ],
            as: BackendExternalTerminalEgressResponse.self
        ).egress
    }

    /// Claims one producer's private reconnect source for this exact connection.
    func claimRemoteTmuxProducerSource(
        producerID: UUID,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource? = nil
    ) async throws -> BackendRemoteTmuxProducerSourceClaimReceipt {
        var parameters: [String: BackendJSONValue] = [
            "producer_id": .string(producerID.uuidString.lowercased()),
            "request_id": .string(requestID.uuidString.lowercased()),
        ]
        if let source {
            parameters["source"] = source.jsonValue
        }
        return try await call(
            command: "claim-remote-tmux-producer-source",
            parameters: parameters,
            as: BackendRemoteTmuxProducerSourceClaimReceipt.self
        )
    }

    /// Replaces one producer's private reconnect source without changing topology.
    func updateRemoteTmuxProducerSource(
        producerID: UUID,
        ownerGeneration: UInt64,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource
    ) async throws -> BackendRemoteTmuxProducerSourceUpdateReceipt {
        try await call(
            command: "update-remote-tmux-producer-source",
            parameters: [
                "producer_id": .string(producerID.uuidString.lowercased()),
                "owner_generation": .unsignedInteger(ownerGeneration),
                "request_id": .string(requestID.uuidString.lowercased()),
                "source": source.jsonValue,
            ],
            as: BackendRemoteTmuxProducerSourceUpdateReceipt.self
        )
    }

    /// Claims one frontend-native browser placement for this exact connection.
    func claimFrontendNativeBrowser(
        surfaceID: SurfaceID,
        requestID: UUID,
        sourceURL: URL?
    ) async throws -> BackendFrontendNativeBrowserClaimReceipt {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(surfaceID.description),
            "request_id": .string(requestID.uuidString.lowercased()),
        ]
        if let sourceURL {
            parameters["source_url"] = .string(sourceURL.absoluteString)
        }
        return try await call(
            command: "claim-frontend-native-browser",
            parameters: parameters,
            as: BackendFrontendNativeBrowserClaimReceipt.self
        )
    }

    /// Replaces the retained source for one exact connection-owned generation.
    /// The daemon keeps this value in memory only and never publishes it in topology.
    func updateFrontendNativeBrowserSource(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        sourceURL: URL
    ) async throws -> BackendFrontendNativeBrowserSourceReceipt {
        try await call(
            command: "update-frontend-native-browser-source",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "owner_generation": .unsignedInteger(ownerGeneration),
                "request_id": .string(requestID.uuidString.lowercased()),
                "source_url": .string(sourceURL.absoluteString),
            ],
            as: BackendFrontendNativeBrowserSourceReceipt.self
        )
    }

    /// Creates one exactly identified frontend-native browser in a new workspace.
    func canonicalNewBrowserWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String? = nil,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["url"] = .string(url.absoluteString)
        parameters["transport"] = .string(
            CanonicalBrowserEndpoint.Transport.frontendNativeV1.rawValue
        )
        if let name { parameters["name"] = .string(name) }
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-new-browser-workspace",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Creates one exactly identified frontend-native browser tab in a stable pane.
    func canonicalNewBrowserTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["url"] = .string(url.absoluteString)
        parameters["transport"] = .string(
            CanonicalBrowserEndpoint.Transport.frontendNativeV1.rawValue
        )
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-new-browser-tab",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Creates one exactly identified frontend-native browser in a new adjacent pane.
    func canonicalSplitBrowserPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["dir"] = .string(direction.rawValue)
        parameters["ratio"] = .number(Double(initialRatio))
        parameters["url"] = .string(url.absoluteString)
        parameters["transport"] = .string(
            CanonicalBrowserEndpoint.Transport.frontendNativeV1.rawValue
        )
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-split-browser-pane",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Creates one terminal in a new pane adjacent to an existing pane.
    func canonicalSplitPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        var parameters = try launch.validatedJSONParameters()
        parameters.merge(expectation.jsonParameters) { _, new in new }
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["dir"] = .string(direction.rawValue)
        parameters["ratio"] = .number(Double(initialRatio))
        if let columns { parameters["cols"] = .unsignedInteger(UInt64(columns)) }
        if let rows { parameters["rows"] = .unsignedInteger(UInt64(rows)) }
        return try await call(
            command: "canonical-split-pane",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Moves an existing terminal into a newly split pane without replacing its runtime.
    func canonicalSplitTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["dir"] = .string(direction.rawValue)
        parameters["ratio"] = .number(Double(initialRatio))
        return try await call(
            command: "canonical-split-tab",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Closes one canonical pane and its contained terminal tabs.
    func canonicalClosePane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["pane_uuid"] = .string(paneID.description)
        return try await call(
            command: "canonical-close-pane",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Closes one canonical surface while preserving any sibling tabs and pane.
    func canonicalCloseSurface(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["surface_uuid"] = .string(surfaceID.description)
        return try await call(
            command: "canonical-close-surface",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Closes one canonical workspace and its contained terminals.
    func canonicalCloseWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuid"] = .string(workspaceID.description)
        return try await call(
            command: "canonical-close-workspace",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Renames one canonical workspace. An empty name remains daemon-defined behavior.
    func canonicalRenameWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuid"] = .string(workspaceID.description)
        parameters["name"] = .string(name)
        return try await call(
            command: "canonical-rename-workspace",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Renames one canonical surface. An empty name clears its custom label.
    func canonicalRenameSurface(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["name"] = .string(name)
        return try await call(
            command: "canonical-rename-surface",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Moves or reorders one surface at an exact pane tab index.
    func canonicalMoveTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        index: UInt64
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["index"] = .unsignedInteger(index)
        return try await call(
            command: "canonical-move-tab",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Reorders one pane's entire tab vector in one commit.
    func canonicalReorderTabs(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["surface_uuids"] = .array(
            surfaceIDs.map { .string($0.description) }
        )
        return try await call(
            command: "canonical-reorder-tabs",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Reorders the complete workspace vector in one commit.
    func canonicalReorderWorkspaces(
        expectation: BackendTopologyMutationExpectation,
        workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["workspace_uuids"] = .array(
            workspaceIDs.map { .string($0.description) }
        )
        return try await call(
            command: "canonical-reorder-workspaces",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Wraps an existing terminal in a newly created workspace without replacing its runtime.
    func canonicalMoveTabToNewWorkspace(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String?,
        index: UInt64?
    ) async throws -> BackendSurfacePlacement {
        var parameters = expectation.jsonParameters
        parameters["surface_uuid"] = .string(surfaceID.description)
        parameters["workspace_uuid"] = .string(workspaceID.description)
        if let name { parameters["name"] = .string(name) }
        if let index { parameters["index"] = .unsignedInteger(index) }
        return try await call(
            command: "canonical-move-tab-to-new-workspace",
            parameters: parameters,
            as: BackendSurfacePlacement.self
        )
    }

    /// Sets the canonical split ratio addressed from one pane edge.
    func canonicalSetSplitRatio(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt {
        var parameters = expectation.jsonParameters
        parameters["pane_uuid"] = .string(paneID.description)
        parameters["dir"] = .string(direction.rawValue)
        parameters["ratio"] = .number(Double(ratio))
        return try await call(
            command: "canonical-set-split-ratio",
            parameters: parameters,
            as: BackendTopologyMutationReceipt.self
        )
    }

    /// Encodes a physical key against canonical terminal modes and writes it to the PTY.
    func sendTerminalKey(
        surface: UInt64,
        event: BackendTerminalKeyEvent
    ) async throws -> BackendTerminalKeyResponse {
        try await call(
            command: "terminal-key",
            parameters: [
                "surface": .unsignedInteger(surface),
                "key": .unsignedInteger(UInt64(event.key)),
                "modifiers": .unsignedInteger(UInt64(event.modifiers)),
                "consumed_modifiers": .unsignedInteger(UInt64(event.consumedModifiers)),
                "text": .string(event.text),
                "unshifted_codepoint": .unsignedInteger(UInt64(event.unshiftedCodepoint)),
                "action": .string(event.action.rawValue),
            ],
            as: BackendTerminalKeyResponse.self
        )
    }

    /// Encodes one Ghostty key-chord name against canonical terminal modes.
    func sendTerminalNamedKey(surface: UInt64, key: String) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "send-key",
            parameters: [
                "surface": .unsignedInteger(surface),
                "keys": .array([.string(key)]),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Encodes terminal mouse input against the backend's canonical modes and geometry.
    func sendTerminalMouse(
        surface: UInt64,
        event: BackendTerminalMouseEvent
    ) async throws -> BackendTerminalMouseResponse {
        var parameters: [String: BackendJSONValue] = [
            "surface": .unsignedInteger(surface),
            "action": .string(event.action.rawValue),
            "modifiers": .unsignedInteger(UInt64(event.modifiers)),
            "x": .number(event.x),
            "y": .number(event.y),
            "viewport_width": .unsignedInteger(UInt64(event.viewportWidth)),
            "viewport_height": .unsignedInteger(UInt64(event.viewportHeight)),
            "cell_width": .unsignedInteger(UInt64(event.cellWidth)),
            "cell_height": .unsignedInteger(UInt64(event.cellHeight)),
            "padding_left": .unsignedInteger(UInt64(event.padding.left)),
            "padding_top": .unsignedInteger(UInt64(event.padding.top)),
            "padding_right": .unsignedInteger(UInt64(event.padding.right)),
            "padding_bottom": .unsignedInteger(UInt64(event.padding.bottom)),
            "any_button_pressed": .bool(event.anyButtonPressed),
            "click_count": .unsignedInteger(UInt64(event.clickCount)),
        ]
        if let button = event.button { parameters["button"] = .string(button.rawValue) }
        return try await call(
            command: "terminal-mouse",
            parameters: parameters,
            as: BackendTerminalMouseResponse.self
        )
    }

    /// Writes committed UTF-8 text, optionally using bracketed-paste semantics.
    func sendTerminalText(
        surface: UInt64,
        text: String,
        paste: Bool = false
    ) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "send",
            parameters: [
                "surface": .unsignedInteger(surface),
                "text": .string(text),
                "paste": .bool(paste),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Applies canonical terminal cell geometry.
    func resizeTerminal(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendSurfaceResizeResponse {
        try await call(
            command: "resize-surface",
            parameters: [
                "surface": .unsignedInteger(surface),
                "cols": .unsignedInteger(UInt64(columns)),
                "rows": .unsignedInteger(UInt64(rows)),
            ],
            as: BackendSurfaceResizeResponse.self
        )
    }

    /// Scrolls presentation state without moving terminal ownership into Swift.
    func scrollTerminal(surface: UInt64, rowDelta: Int64) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "scroll-surface",
            parameters: [
                "surface": .unsignedInteger(surface),
                "delta": .integer(rowDelta),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Reads the coherent daemon-owned selection, search, copy-mode, and viewport state.
    func terminalState(surfaceID: SurfaceID) async throws -> BackendTerminalStateResponse {
        try await call(
            command: "terminal-state",
            parameters: ["surface_uuid": .string(surfaceID.description)],
            as: BackendTerminalStateResponse.self
        )
    }

    /// Reads one bounded semantic accessibility snapshot for an owned presentation.
    func terminalAccessibilitySnapshot(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64
    ) async throws -> BackendTerminalAccessibilitySnapshot {
        try await call(
            command: "terminal-accessibility-snapshot",
            parameters: [
                "presentation_id": .string(presentationID.description),
                "expected_generation": .unsignedInteger(expectedGeneration),
                "expected_content_sequence": .unsignedInteger(expectedContentSequence),
            ],
            as: BackendTerminalAccessibilitySnapshot.self
        )
    }

    /// Revalidates a snapshot revision and OSC 8 identity before returning its target.
    func activateTerminalAccessibilityLink(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        terminalRevision: UInt64,
        contentRevision: UInt64,
        viewportRevision: UInt64,
        linkID: String
    ) async throws -> BackendTerminalAccessibilityLinkActivation {
        try await call(
            command: "terminal-accessibility-activate-link",
            parameters: [
                "presentation_id": .string(presentationID.description),
                "expected_generation": .unsignedInteger(expectedGeneration),
                "terminal_revision": .unsignedInteger(terminalRevision),
                "content_revision": .unsignedInteger(contentRevision),
                "viewport_revision": .unsignedInteger(viewportRevision),
                "link_id": .string(linkID),
            ],
            as: BackendTerminalAccessibilityLinkActivation.self
        )
    }

    /// Resolves an OSC 8 link only when the clicked cell still belongs to the
    /// exact semantic frame admitted by the host compositor.
    func terminalHyperlinkAtCell(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64,
        column: UInt16,
        row: UInt16
    ) async throws -> BackendTerminalHyperlinkHit {
        try await call(
            command: "terminal-link-at-cell",
            parameters: [
                "presentation_id": .string(presentationID.description),
                "expected_generation": .unsignedInteger(expectedGeneration),
                "expected_content_sequence": .unsignedInteger(expectedContentSequence),
                "column": .unsignedInteger(UInt64(column)),
                "row": .unsignedInteger(UInt64(row)),
            ],
            as: BackendTerminalHyperlinkHit.self
        )
    }

    /// Applies one Ghostty binding-action string to canonical backend state.
    func performTerminalBindingAction(
        surfaceID: SurfaceID,
        action: String,
        repeatCount: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(surfaceID.description),
            "action": .string(action),
        ]
        if let repeatCount {
            parameters["repeat_count"] = .unsignedInteger(UInt64(repeatCount))
        }
        return try await call(
            command: "terminal-binding-action",
            parameters: parameters,
            as: BackendTerminalActionResponse.self
        )
    }

    /// Reads or mutates the canonical terminal selection.
    func terminalSelection(
        surfaceID: SurfaceID,
        operation: BackendTerminalSelectionOperation
    ) async throws -> BackendTerminalSelectionResponse {
        try await call(
            command: "terminal-selection",
            parameters: [
                "surface_uuid": .string(surfaceID.description),
                "operation": .string(operation.rawValue),
            ],
            as: BackendTerminalSelectionResponse.self
        )
    }

    /// Enters, exits, or adjusts backend-owned keyboard copy mode.
    func terminalCopyMode(
        surfaceID: SurfaceID,
        operation: BackendTerminalCopyModeOperation,
        adjustment: BackendTerminalCopyModeAdjustment? = nil,
        count: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(surfaceID.description),
            "operation": .string(operation.rawValue),
        ]
        if let adjustment { parameters["adjustment"] = .string(adjustment.rawValue) }
        if let count { parameters["count"] = .unsignedInteger(UInt64(count)) }
        return try await call(
            command: "terminal-copy-mode",
            parameters: parameters,
            as: BackendTerminalActionResponse.self
        )
    }

    /// Updates canonical terminal search state.
    func terminalSearch(
        surfaceID: SurfaceID,
        operation: BackendTerminalSearchOperation,
        query: String? = nil
    ) async throws -> BackendTerminalActionResponse {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(surfaceID.description),
            "operation": .string(operation.rawValue),
        ]
        if let query { parameters["query"] = .string(query) }
        return try await call(
            command: "terminal-search",
            parameters: parameters,
            as: BackendTerminalActionResponse.self
        )
    }

    /// Scrolls the backend-owned terminal viewport.
    func terminalScroll(
        surfaceID: SurfaceID,
        operation: BackendTerminalScrollOperation,
        amount: Int64? = nil
    ) async throws -> BackendTerminalActionResponse {
        var parameters: [String: BackendJSONValue] = [
            "surface_uuid": .string(surfaceID.description),
            "operation": .string(operation.rawValue),
        ]
        if let amount { parameters["amount"] = .integer(amount) }
        return try await call(
            command: "terminal-scroll",
            parameters: parameters,
            as: BackendTerminalActionResponse.self
        )
    }

    /// Reads the backend's canonical viewport text for accessibility and automation.
    func readTerminalScreen(surface: UInt64) async throws -> BackendScreenText {
        try await call(
            command: "read-screen",
            parameters: ["surface": .unsignedInteger(surface)],
            as: BackendScreenText.self
        )
    }

    /// Reads PTY process metadata from the backend owner.
    func terminalProcessInfo(surface: UInt64) async throws -> BackendProcessInfo {
        try await call(
            command: "process-info",
            parameters: ["surface": .unsignedInteger(surface)],
            as: BackendProcessInfo.self
        )
    }

    /// Closes the canonical PTY surface explicitly.
    func closeTerminal(surface: UInt64) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "close-surface",
            parameters: ["surface": .unsignedInteger(surface)],
            as: BackendEmptyResponse.self
        )
    }
}
