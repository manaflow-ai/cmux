public import CmuxNextWakeups

/// The App's pull request reads with the user's GitHub CLI (cx-mb1e0), made once by the composition root: one
/// reader, whose runner every chat header's chip, the sidebar's badges and the reply cards share, so at most two
/// gh run at once however many chats restore offline; and the reply cards' cache, which reads through it.
///
/// ```swift
/// let reads = AgentPullRequestReads(mainWork: mainWork)
/// let chip = AgentChatPullRequest(reader: reads.reader)
/// links.pullRequest = { reads.replies.answer($0) }
/// ```
@MainActor
public final class AgentPullRequestReads {
    /// The reader every pull request read goes through.
    public let reader: AgentChatPullRequestReader
    /// The reply links' and the changelog's pull request cards.
    public let replies: AgentReplyPullRequests

    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler, where the cards' answers land.
    ///   - processes: what runs gh; by default ``AsyncProcess``, two runs at a time.
    public init(mainWork: MainWorkScheduler, processes: any ProcessRunning = BoundedProcessRunner(AsyncProcess(), atOnce: 2)) {
        reader = AgentChatPullRequestReader(processes: processes)
        replies = AgentReplyPullRequests(reader: reader, mainWork: mainWork)
    }
}
