import Foundation

/// A workspace provider that can report where a terminal's shell currently
/// is, so the Files chip opens the SFTP browser there.
///
/// A separate refinement rather than a requirement on
/// ``MobileSSHWorkspaceProvider``: providers opt in by conforming (tmux via
/// `#{pane_current_path}`, cmux-tui via `process-info`, plain shells via the
/// OSC 7 reports in their output). A `nil` answer (unknown) starts the
/// browser in the remote home folder, which is where a login shell starts.
@MainActor
protocol MobileSSHCurrentDirectoryProviding: MobileSSHWorkspaceProvider {
    /// The absolute remote path of the terminal's current directory, or
    /// `nil` when unknown.
    func currentDirectory(terminalID: String) async -> String?
}

extension MobileSSHWorkspaceProvider {
    /// The terminal's current directory when this provider conforms to
    /// ``MobileSSHCurrentDirectoryProviding``, otherwise `nil`.
    func reportedCurrentDirectory(terminalID: String) async -> String? {
        guard let provider = self as? any MobileSSHCurrentDirectoryProviding else { return nil }
        return await provider.currentDirectory(terminalID: terminalID)
    }
}
