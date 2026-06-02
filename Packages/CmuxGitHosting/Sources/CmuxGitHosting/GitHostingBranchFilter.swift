/// Describes how a provider narrows its pull request list to a single source branch.
///
/// When present, the cmux poller can ask the provider for just the requests opened
/// from a workspace's branch (instead of scanning every open request) by appending
/// one query item whose value is ``valueTemplate`` with `{branch}`/`{owner}`
/// substituted. Examples:
///
/// - GitHub: `name = "head"`, `valueTemplate = "{owner}:{branch}"`
/// - GitLab: `name = "source_branch"`, `valueTemplate = "{branch}"`
/// - Bitbucket: `name = "q"`, `valueTemplate = "source.branch.name=\"{branch}\""`
///
/// A provider with no branch filter simply omits this; the poller then matches
/// branches against the full list it already fetches.
public struct GitHostingBranchFilter: Sendable, Codable, Equatable {
    /// The query parameter name used to filter by source branch.
    public var name: String

    /// The query value template, with `{branch}` / `{owner}` tokens substituted.
    public var valueTemplate: String

    /// Creates a branch filter.
    public init(name: String, valueTemplate: String) {
        self.name = name
        self.valueTemplate = valueTemplate
    }
}
