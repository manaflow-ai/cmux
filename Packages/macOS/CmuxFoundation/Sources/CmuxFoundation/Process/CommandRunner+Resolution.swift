extension CommandRunner {
    /// Resolves `executable` to an absolute path using the runner's configured search policy.
    func resolvedCommandPath(executable: String) -> String? {
        commandPathResolver.resolve(executable)
    }
}
