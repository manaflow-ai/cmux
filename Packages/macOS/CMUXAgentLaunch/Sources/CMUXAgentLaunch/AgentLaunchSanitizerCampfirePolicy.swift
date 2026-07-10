import Foundation

extension AgentLaunchSanitizer {
    /// Campfire embeds vanilla pi and forwards unrecognized flags to it, so its
    /// policy is pi's plus the campfire-only surface. `--relay` is safe to
    /// replay (a relay URL, not a credential); `--join-as`/`--name` are
    /// joiner-only display names that make no sense on a host resume. An invite
    /// URL is a positional argument and is dropped by the default positional
    /// handling because it carries the lobby capability token and must never be
    /// persisted or replayed.
    static let campfirePolicy: Policy = {
        var policy = piPolicy
        policy.valueOptions.formUnion(["--relay", "--join", "--join-as", "--name"])
        policy.nonRestorableCommands.insert("init")
        policy.droppedOptions.formUnion(["--join", "--join-as", "--name", "--auto-exit"])
        policy.droppedOptionPrefixes.append(contentsOf: ["--join=", "--join-as=", "--name="])
        return policy
    }()
}
