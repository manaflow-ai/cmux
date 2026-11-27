extension String {
    /// The branch name trimmed of whitespace, or `nil` when empty.
    /// Formerly the file-private `normalizedSidebarBranchName(_:)` helper.
    public var normalizedSidebarBranchName: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
