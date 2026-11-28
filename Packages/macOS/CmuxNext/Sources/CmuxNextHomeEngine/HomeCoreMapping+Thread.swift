import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The owner's thread and page reads (`conversation-thread-v1`, cx-59n8.6) as the shared Home
/// core's types, through the `mapping.thread`, `threadPage`, `conversationPage` and `historyPage`
/// ops. `identity`: a cloud owner's rows (its account's id as Home's); nil keeps every id.
nonisolated extension HomeCoreMapping {
    private struct PageRequest: Encodable {
        let page: HomeCoreMapping.WirePage
        let identity: HomeCoreMapping.Identity?
        let chiefName: String?
    }

    static func thread(_ summary: ConversationThreadSummary, identity: CloudIdentity? = nil) -> ThreadSummary {
        struct Request: Encodable {
            let summary: HomeCoreMapping.WireThread
            let identity: HomeCoreMapping.Identity?
        }
        struct Reply: Decodable { let thread: HomeCoreMapping.ThreadRow }
        return HomeCoreMapping.mappingRule("thread", Request(summary: .init(summary), identity: identity.map(HomeCoreMapping.Identity.init)),
                                            fallback: Reply?.none)?.thread.thread ?? HomeCoreMapping.plainThread(summary)
    }

    static func threadPage(_ page: ConversationThread, identity: CloudIdentity? = nil) -> ThreadPage {
        struct Request: Encodable {
            let page: HomeCoreMapping.WireThreadPage
            let identity: HomeCoreMapping.Identity?
        }
        return HomeCoreMapping.mappingRule("threadPage", Request(page: .init(page), identity: identity.map(HomeCoreMapping.Identity.init)),
                                            fallback: HomeCoreMapping.ThreadPageRow?.none)?.page
            ?? ThreadPage(root: message(page.root, identity: identity), replies: page.replies.map { message($0, identity: identity) },
                          hasMore: page.hasMore, summary: thread(page.thread, identity: identity))
    }

    /// A local snapshot as a Home page (`mapping.conversationPage`).
    static func conversationPage(_ page: ConversationSnapshot) -> ConversationPage {
        let request = PageRequest(page: .init(conversation: page.conversation, messages: page.messages, threads: page.threads.map(HomeCoreMapping.WireThread.init)),
                                  identity: nil, chiefName: HomeStrings.chiefName)
        return HomeCoreMapping.mappingRule("conversationPage", request, fallback: HomeCoreMapping.ConversationPageRow?.none)?.page
            ?? ConversationPage(conversation: summary(page.conversation), messages: page.messages.map { message($0) },
                                threads: page.threads.map { thread($0) })
    }

    /// An older page as a Home page (`mapping.historyPage`).
    static func historyPage(messages: [ConversationMessage], threads: [ConversationThreadSummary], identity: CloudIdentity? = nil) -> HistoryPage {
        let request = PageRequest(page: .init(conversation: nil, messages: messages, threads: threads.map(HomeCoreMapping.WireThread.init)),
                                  identity: identity.map(HomeCoreMapping.Identity.init), chiefName: nil)
        return HomeCoreMapping.mappingRule("historyPage", request, fallback: HomeCoreMapping.HistoryPageRow?.none)?.page
            ?? HistoryPage(messages: messages.map { message($0, identity: identity) }, threads: threads.map { thread($0, identity: identity) })
    }

    /// Whether `error` says the daemon has no thread read (fall back to a history scan).
    static func lacksThreadRead(_ error: any Error) -> Bool {
        if case DaemonError.missingCapabilities = error { return true }
        return false
    }
}
