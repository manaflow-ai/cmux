import CmuxCloudMachines
import Foundation

/// Owns the input boundary before any tree traversal, reconciliation or formatting.
@MainActor
final class CloudTreeNodeCache {
    private var inputs: CloudTreeBuildInputs?
    private var evaluatedAt = Date.distantPast
    private var nextResourceTransition = Date.distantFuture
    private let resources: CloudTreeMachineResourceCache
    private let buildNodes: ((CloudTreeBuildInputs) -> [CloudTreeNode])?

    init(
        resources: CloudTreeMachineResourceCache? = nil,
        buildNodes: ((CloudTreeBuildInputs) -> [CloudTreeNode])? = nil
    ) {
        self.resources = resources ?? CloudTreeMachineResourceCache()
        self.buildNodes = buildNodes
    }

    func nodes(ifChanged inputs: CloudTreeBuildInputs, now: Date) -> [CloudTreeNode]? {
        if inputs == self.inputs, now >= evaluatedAt, now < nextResourceTransition { return nil }
        // Publish the boundary before reconciliation can cause a reentrant render.
        self.inputs = inputs
        evaluatedAt = now
        nextResourceTransition = .distantFuture
        for machine in inputs.machines where machine.capabilities.stats {
            guard let stats = machine.stats, stats.state == .awake,
                  let sampledAt = stats.resourceSampledAt else { continue }
            let expiry = Date(timeIntervalSince1970:
                (sampledAt.timeIntervalSince1970 + CloudMachineResourcePresentation.staleSampleAge).nextUp)
            let transition = sampledAt > now ? sampledAt : expiry
            if transition > now { nextResourceTransition = min(nextResourceTransition, transition) }
        }
        resources.beginBuild(locale: inputs.localeIdentifier)
        defer { resources.endBuild() }
        if let buildNodes { return buildNodes(inputs) }
        return inputs.nodes(now: now, resourceNodeBuilder: .init(section: { [resources] machine, now in
            resources.section(machine: machine, now: now)
        }))
    }
}
