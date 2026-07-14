import CmuxFoundation
import Foundation

extension CmuxWorkspaceDefinition {
    /// Resolves every launch-time string leaf before workspace state is mutated.
    func resolvingTemplateParameters(
        _ explicitParameters: [String: String],
        processEnvironment: [String: String]
    ) throws -> CmuxWorkspaceDefinition {
        let resolver = templateResolver(
            explicitParameters: explicitParameters,
            processEnvironment: processEnvironment
        )
        let values = try resolver.resolvedValues(for: templateStrings)
        return substitutingTemplateValues(values)
    }

    func templateResolver(
        explicitParameters: [String: String],
        processEnvironment: [String: String]
    ) -> CmuxTemplateResolver {
        let workspaceEnvironment = (env ?? [:]).filter { _, value in
            !CmuxTemplate(value).containsVariables
        }
        return CmuxTemplateResolver(
            explicitValues: explicitParameters,
            definitionValues: params ?? [:],
            workspaceEnvironment: workspaceEnvironment,
            processEnvironment: processEnvironment
        )
    }

    func substitutingTemplateValues(_ values: [String: String]) -> CmuxWorkspaceDefinition {
        return CmuxWorkspaceDefinition(
            name: name.map { CmuxTemplate($0).substituting(values) },
            cwd: cwd.map { CmuxTemplate($0).substituting(values) },
            color: color,
            env: env?.mapValues { CmuxTemplate($0).substituting(values) },
            setup: setup.map { CmuxTemplate($0).substituting(values) },
            params: nil,
            layout: layout?.substitutingTemplateValues(values)
        )
    }

    var templateStrings: [CmuxTemplate] {
        var templates = [name, cwd, setup].compactMap { $0 }.map(CmuxTemplate.init)
        templates.append(contentsOf: (env ?? [:]).keys.sorted().compactMap { key in
            env?[key].map(CmuxTemplate.init)
        })
        if let layout {
            templates.append(contentsOf: layout.templateStrings)
        }
        return templates
    }
}

private extension CmuxLayoutNode {
    var templateStrings: [CmuxTemplate] {
        switch self {
        case .pane(let pane):
            return pane.surfaces.flatMap(\.templateStrings)
        case .split(let split):
            return split.children.flatMap(\.templateStrings)
        }
    }

    func substitutingTemplateValues(_ values: [String: String]) -> CmuxLayoutNode {
        switch self {
        case .pane(let pane):
            return .pane(CmuxPaneDefinition(
                surfaces: pane.surfaces.map { $0.substitutingTemplateValues(values) }
            ))
        case .split(let split):
            return .split(CmuxSplitDefinition(
                direction: split.direction,
                split: split.split,
                children: split.children.map { $0.substitutingTemplateValues(values) }
            ))
        }
    }
}

private extension CmuxSurfaceDefinition {
    var templateStrings: [CmuxTemplate] {
        var templates = [name, command, cwd].compactMap { $0 }.map(CmuxTemplate.init)
        templates.append(contentsOf: (env ?? [:]).keys.sorted().compactMap { key in
            env?[key].map(CmuxTemplate.init)
        })
        if let url {
            templates.append(CmuxTemplate(url))
        }
        return templates
    }

    func substitutingTemplateValues(_ values: [String: String]) -> CmuxSurfaceDefinition {
        CmuxSurfaceDefinition(
            type: type,
            name: name.map { CmuxTemplate($0).substituting(values) },
            command: command.map { CmuxTemplate($0).substituting(values) },
            cwd: cwd.map { CmuxTemplate($0).substituting(values) },
            env: env?.mapValues { CmuxTemplate($0).substituting(values) },
            url: url.map { CmuxTemplate($0).substituting(values) },
            focus: focus
        )
    }
}
