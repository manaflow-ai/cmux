actor FailedThenRecoveredTaskModelProbe {
    var requests = 0

    func run(_ command: String) -> String? {
        if command.hasPrefix("command -v") { return "/bin/opencode" }
        requests += 1
        guard requests > 1 else { return nil }
        return "opencode/recovered\n{\"name\":\"Recovered\",\"variants\":{}}"
    }
}
