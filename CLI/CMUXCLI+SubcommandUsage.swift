import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Per-subcommand usage text
extension CMUXCLI {
    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    func subcommandUsage(_ command: String) -> String? {
        if let usage = coreSubcommandUsage(command) { return usage }
        if let usage = windowWorkspaceSubcommandUsage(command) { return usage }
        if let usage = paneSurfaceSubcommandUsage(command) { return usage }
        if let usage = tmuxCompatSubcommandUsage(command) { return usage }
        if let usage = notificationStatusSubcommandUsage(command) { return usage }
        if let usage = browserViewerSubcommandUsage(command) { return usage }
        return nil
    }

}
