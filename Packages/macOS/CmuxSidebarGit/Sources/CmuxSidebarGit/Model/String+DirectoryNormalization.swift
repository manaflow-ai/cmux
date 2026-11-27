public import Foundation

extension String {
    /// The directory string normalized for git probing: trimmed of
    /// whitespace, with `file://` URLs reduced to their filesystem path.
    /// Returns the original string when trimming leaves it empty (matching
    /// the legacy `TabManager.normalizeDirectory` behavior byte for byte).
    public var normalizedGitProbeDirectory: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    /// ``normalizedGitProbeDirectory`` collapsed to `nil` when the normalized
    /// value is effectively empty (matching the legacy
    /// `TabManager.normalizedWorkingDirectory` behavior: the non-nil result is
    /// the normalized string, not the trimmed probe).
    public var nonEmptyNormalizedGitProbeDirectory: String? {
        let normalized = normalizedGitProbeDirectory
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }
}
