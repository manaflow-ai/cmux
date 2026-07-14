/// Coerces raw `--param key=value` strings against a manifest's declared
/// parameter types. Shared by the CLI interview and the socket run path so
/// both validate identically.
public enum OrchestrationParameterResolution {
    public static func coerce(
        overrides: [String: String],
        manifest: OrchestrationManifest
    ) -> Result<[String: OrchestrationParameterValue], OrchestrationParameterProblem> {
        var resolved: [String: OrchestrationParameterValue] = [:]
        for (key, rawValue) in overrides {
            guard let parameter = manifest.parameters.first(where: { $0.key == key }) else {
                return .failure(OrchestrationParameterProblem(
                    key: key,
                    reason: "is not a parameter of this template"
                ))
            }
            switch parameter.coerce(rawValue) {
            case .success(let value):
                resolved[key] = value
            case .failure(let problem):
                return .failure(problem)
            }
        }
        return .success(resolved)
    }
}
