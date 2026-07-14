import CmuxControlSocket
import CmuxOrchestration
import Foundation

/// The orchestration-domain witnesses for ``ControlCommandCoordinator``:
/// reads the installed-template store, plans runs through
/// `CmuxOrchestration`, enforces the trust gate, and hands accepted plans to
/// ``OrchestrationRunController`` for actuation. Store and template files
/// are small JSON documents (the `SavedLayoutStore` precedent), so reads
/// happen inline; provisioning always leaves the main actor.
extension TerminalController: ControlOrchestrationContext {
    private var orchestrationStore: OrchestrationStore { OrchestrationStore() }

    private var orchestrationCmuxVersion: OrchestrationVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(OrchestrationVersion.init(string:))
    }

    func controlOrchestrationList() -> ControlOrchestrationListResolution {
        do {
            let store = orchestrationStore
            return .resolved(try store.list().map { Self.orchestrationSummary($0, store: store) })
        } catch {
            return .failed(String(describing: error))
        }
    }

    func controlOrchestrationInfo(name: String) -> ControlOrchestrationInfoResolution {
        let store = orchestrationStore
        do {
            let installation = try store.installed(named: name)
            return .resolved(
                summary: Self.orchestrationSummary(installation, store: store),
                detail: Self.orchestrationDetail(installation)
            )
        } catch {
            if case OrchestrationStoreError.notInstalled = error {
                return .notInstalled
            }
            return .failed(String(describing: error))
        }
    }

    func controlOrchestrationPlan(
        inputs: ControlOrchestrationRunInputs
    ) -> ControlOrchestrationPlanResolution {
        switch orchestrationPlan(inputs: inputs) {
        case .notInstalled:
            return .notInstalled
        case .planFailed(let message):
            return .planFailed(message)
        case .failed(let message):
            return .failed(message)
        case .planned(let plan, let installation):
            guard let payload = Self.orchestrationJSON(plan) else {
                return .failed("Could not encode run plan")
            }
            return .resolved(plan: payload, trustConfirmed: installation.record.trustConfirmedAt != nil)
        }
    }

    func controlOrchestrationRun(
        routing: ControlRoutingSelectors,
        inputs: ControlOrchestrationRunInputs,
        confirmTrust: Bool
    ) -> ControlOrchestrationRunResolution {
        let store = orchestrationStore
        switch orchestrationPlan(inputs: inputs) {
        case .notInstalled:
            return .notInstalled
        case .planFailed(let message):
            return .planFailed(message)
        case .failed(let message):
            return .failed(message)
        case .planned(let plan, let installation):
            if installation.record.trustConfirmedAt == nil {
                guard confirmTrust else {
                    return .needsTrustConfirmation(
                        trust: Self.orchestrationJSON(plan.trust) ?? .object([:])
                    )
                }
                do {
                    _ = try store.confirmTrust(name: inputs.name)
                } catch {
                    return .failed(String(describing: error))
                }
            }
            guard let tabManager = resolveTabManager(routing: routing) else {
                return .failed("TabManager not available")
            }
            OrchestrationRunController.shared.start(plan: plan, tabManager: tabManager)
            return .started(.object([
                "status": .string("started"),
                "run_id": .string(plan.runID),
                "group": .string(plan.groupName),
                "agent": .string(plan.agentID),
                "workspace_root": .string(plan.workspaceRoot),
                "notes": .array(plan.notes.map { .string($0) }),
                "workspaces": .array(plan.workspaces.map { workspace in
                    .object([
                        "title": .string(workspace.title),
                        "directory": .string(workspace.directory),
                        "branch": workspace.branch.map { .string($0) } ?? .null,
                    ])
                }),
            ]))
        }
    }

    // MARK: - Shared planning

    private enum OrchestrationPlanOutcome {
        case notInstalled
        case planFailed(String)
        case failed(String)
        case planned(OrchestrationRunPlan, InstalledOrchestration)
    }

    private func orchestrationPlan(inputs: ControlOrchestrationRunInputs) -> OrchestrationPlanOutcome {
        let installation: InstalledOrchestration
        do {
            installation = try orchestrationStore.installed(named: inputs.name)
        } catch {
            if case OrchestrationStoreError.notInstalled = error {
                return .notInstalled
            }
            return .failed(String(describing: error))
        }

        let overrides: [String: OrchestrationParameterValue]
        switch OrchestrationParameterResolution.coerce(
            overrides: inputs.parameterOverrides,
            manifest: installation.manifest
        ) {
        case .success(let coerced):
            overrides = coerced
        case .failure(let problem):
            return .planFailed("Parameter '\(problem.key)' \(problem.reason)")
        }

        let request = OrchestrationRunPlanner.Request(
            installation: installation,
            tasks: inputs.tasks.map {
                OrchestrationTaskInput(title: $0.title, body: $0.body, issueNumber: $0.issueNumber)
            },
            parameterOverrides: overrides,
            agentID: inputs.agentID,
            runID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            cmuxVersion: orchestrationCmuxVersion
        )
        do {
            return .planned(try OrchestrationRunPlanner().plan(request), installation)
        } catch let error as OrchestrationPlanError {
            return .planFailed(error.message)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - Payload builders

    private static func orchestrationSummary(
        _ installation: InstalledOrchestration,
        store: OrchestrationStore
    ) -> ControlOrchestrationSummary {
        ControlOrchestrationSummary(
            name: installation.manifest.name,
            version: installation.manifest.version,
            description: installation.manifest.description,
            substrate: installation.manifest.substrate.kind.rawValue,
            agentIDs: installation.manifest.agents.map(\.id),
            sourceDisplay: installation.record.source.displayName,
            trustConfirmed: installation.record.trustConfirmedAt != nil,
            unansweredParameterKeys: store.unanswered(
                manifest: installation.manifest,
                record: installation.record
            ).map(\.key)
        )
    }

    private static func orchestrationDetail(_ installation: InstalledOrchestration) -> JSONValue {
        let manifest = installation.manifest
        let record = installation.record
        var detail: [String: JSONValue] = [
            "template_directory": .string(installation.templateDirectory),
            "installed_at": .string(CmuxEventBus.isoTimestamp(record.installedAt)),
            "author": manifest.author.map { .string($0) } ?? .null,
            "min_cmux_version": manifest.minCmuxVersion.map { .string($0) } ?? .null,
            "prompt": manifest.prompt.map { .string($0) } ?? .null,
            "layout": manifest.layout.map { .string($0) } ?? .null,
            "workflow": manifest.workflow.map { .string($0) } ?? .null,
            "parameters": .array(manifest.parameters.map { parameter in
                .object([
                    "key": .string(parameter.key),
                    "prompt": .string(parameter.prompt),
                    "type": .string(parameter.type.rawValue),
                    "default": parameter.defaultValue.map { .string($0.description) } ?? .null,
                    "answered": .bool(record.resolvedParameters[parameter.key] != nil),
                ])
            }),
        ]
        if let updatedAt = record.updatedAt {
            detail["updated_at"] = .string(CmuxEventBus.isoTimestamp(updatedAt))
        }
        if let steps = manifest.steps {
            detail["steps"] = .array(steps.map { step in
                .object([
                    "id": .string(step.id),
                    "agent": .string(step.agent),
                    "prompt": .string(step.prompt),
                ])
            })
        }
        return .object(detail)
    }

    /// Bridges any `Encodable` package value to the wire `JSONValue`.
    private static func orchestrationJSON(_ value: some Encodable) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return JSONValue(foundationObject: object)
    }
}
