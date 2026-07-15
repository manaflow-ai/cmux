/// Resolves cmux templates through one documented parameter-precedence model.
///
/// Resolution precedence is explicit invocation values, definition defaults,
/// literal workspace-level environment values, process environment values, and
/// finally inline `{{name=default}}` values.
public struct CmuxTemplateResolver: Sendable {
    /// Values supplied explicitly by the invocation surface.
    public let explicitValues: [String: String]

    /// Defaults declared by the containing definition's `params` block.
    public let definitionValues: [String: String]

    /// Literal values from the workspace-level environment.
    public let workspaceEnvironment: [String: String]

    /// Values inherited from the launching process environment.
    public let processEnvironment: [String: String]

    /// Creates a resolver with explicit dependency values.
    ///
    /// - Parameters:
    ///   - explicitValues: Invocation values, such as CLI `--param` entries.
    ///   - definitionValues: Defaults from a workspace `params` block.
    ///   - workspaceEnvironment: Literal workspace-level environment values.
    ///   - processEnvironment: The launcher's environment. Callers inject this
    ///     explicitly so tests never depend on global process state.
    public init(
        explicitValues: [String: String] = [:],
        definitionValues: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:],
        processEnvironment: [String: String] = [:]
    ) {
        self.explicitValues = explicitValues
        self.definitionValues = definitionValues
        self.workspaceEnvironment = workspaceEnvironment
        self.processEnvironment = processEnvironment
    }

    /// Resolves one template or throws with every missing variable it contains.
    ///
    /// - Parameter template: The template to resolve.
    /// - Returns: Concrete text with recognized placeholders substituted.
    /// - Throws: ``CmuxTemplateResolutionError/missingVariables(_:)`` when a
    ///   required variable has no value.
    public func resolve(_ template: CmuxTemplate) throws -> String {
        let values = try resolvedValues(for: [template])
        return template.substituting(values)
    }

    /// Resolves a batch atomically after preflighting every required variable.
    ///
    /// - Parameter templates: Templates in deterministic traversal order.
    /// - Returns: Concrete strings in the same order.
    /// - Throws: ``CmuxTemplateResolutionError/missingVariables(_:)`` listing
    ///   every missing name once, in first-occurrence order.
    public func resolve(_ templates: [CmuxTemplate]) throws -> [String] {
        let values = try resolvedValues(for: templates)
        return templates.map { $0.substituting(values) }
    }

    /// Computes the single value map used to render a batch of templates.
    ///
    /// - Parameter templates: Templates in deterministic traversal order.
    /// - Returns: Values for every recognized variable.
    /// - Throws: ``CmuxTemplateResolutionError/missingVariables(_:)`` listing
    ///   every missing name once, in first-occurrence order.
    public func resolvedValues(for templates: [CmuxTemplate]) throws -> [String: String] {
        var values: [String: String] = [:]
        var missing: [String] = []
        var seen = Set<String>()

        for variable in templates.flatMap(\.variables) where seen.insert(variable.name).inserted {
            if let value = value(for: variable) {
                values[variable.name] = value
            } else {
                missing.append(variable.name)
            }
        }
        guard missing.isEmpty else {
            throw CmuxTemplateResolutionError.missingVariables(missing)
        }
        return values
    }

    /// Describes the editable values needed by a launch UI.
    ///
    /// Inputs preserve first-occurrence order and use the same precedence as
    /// final resolution, so a prompt can prefill the value that would otherwise
    /// be selected automatically.
    public func parameterInputs(for templates: [CmuxTemplate]) -> [CmuxTemplateParameterInput] {
        var seen = Set<String>()
        return templates.flatMap(\.variables).compactMap { variable in
            guard seen.insert(variable.name).inserted else { return nil }
            return CmuxTemplateParameterInput(
                name: variable.name,
                suggestedValue: value(for: variable)
            )
        }
    }

    private func value(for variable: CmuxTemplateVariable) -> String? {
        explicitValues[variable.name]
            ?? definitionValues[variable.name]
            ?? workspaceEnvironment[variable.name]
            ?? processEnvironment[variable.name]
            ?? variable.defaultValue
    }
}
