import Foundation

/// The user-facing text of Cloud environments (plans/cmux-next/cloud-environments-DESIGN.md), in
/// Resources/Cloud.xcstrings with every app locale.
public nonisolated struct CloudEnvironmentStrings: Sendable {
    public init() {}

    /// An environment asked for on the classic `/api/vm` Cloud path, which has none.
    public var unavailable: String {
        String(localized: "cloud.environments.unavailable",
               defaultValue: "Cloud environments need the cmux-next Cloud connection. Create the machine without an environment, or switch the Cloud connection to cmux-next.",
               table: "Cloud", bundle: .module)
    }

    /// A Build or Delete for an environment the page no longer names.
    public var unknown: String {
        String(localized: "cloud.environments.unknown", defaultValue: "That environment no longer exists. Refresh the list.", table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --environment` (and `cloud start-chat --environment`) with no word, or a name none of
    /// the team's environments has.
    public var unknownWord: String {
        String(localized: "cloud.environments.unknownWord",
               defaultValue: "--environment takes the id (env_…) or the name of one of your team's Cloud environments.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --environment NAME` when the team's environments could not be read.
    public var listUnread: String {
        String(localized: "cloud.environments.listUnread",
               defaultValue: "Couldn't read your team's Cloud environments, so no machine was made. Run the command again in a moment.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --name N --environment E` when the machine list is not current: N may exist already.
    public func nameUnread(_ name: String) -> String {
        String(format: String(localized: "cloud.environments.nameUnread",
                              defaultValue: "Couldn't read your Cloud machines, so no machine was made in the environment: one named %@ may already exist. Check `cmux cloud list-machines`, then run the command again.",
                              table: "Cloud", bundle: .module), name)
    }

    /// `cloud new-machine --name N --environment E` when a machine named N exists or is being made.
    public func nameTaken(_ name: String) -> String {
        String(format: String(localized: "cloud.environments.nameTaken",
                              defaultValue: "A Cloud machine named %@ already exists or is being made, so no second one was made. Use it with --target machine:ID from `cmux cloud list-machines`, or give a new --name.",
                              table: "Cloud", bundle: .module), name)
    }

    /// The Build confirmation's title for the environment named `name`.
    public func buildTitle(_ name: String) -> String {
        String(format: String(localized: "cloud.environments.buildTitle", defaultValue: "Build %@?", table: "Cloud", bundle: .module), name)
    }

    /// What a build does and costs.
    public var buildBody: String {
        String(localized: "cloud.environments.buildBody",
               defaultValue: "A builder machine clones the repository and runs the setup, is saved as a snapshot, and is deleted. It runs for a few minutes, and the snapshot counts toward your saved snapshots. New machines in this environment then start in about a second.",
               table: "Cloud", bundle: .module)
    }

    public var buildButton: String {
        String(localized: "cloud.environments.buildButton", defaultValue: "Build", table: "Cloud", bundle: .module)
    }

    /// The Delete confirmation's title for the environment named `name`.
    public func deleteTitle(_ name: String) -> String {
        String(format: String(localized: "cloud.environments.deleteTitle", defaultValue: "Delete %@?", table: "Cloud", bundle: .module), name)
    }

    /// What a delete removes, and what stays.
    public var deleteBody: String {
        String(localized: "cloud.environments.deleteBody",
               defaultValue: "This deletes the environment and its snapshot. Machines started from it keep running.",
               table: "Cloud", bundle: .module)
    }

    public var deleteButton: String {
        String(localized: "cloud.environments.deleteButton", defaultValue: "Delete", table: "Cloud", bundle: .module)
    }
}
