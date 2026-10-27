/// How a tab's hidden content is released (p07-memory.md DC4, MQ-CONTENT).
package nonisolated enum TabContentDiscard: Hashable, Sendable {
    /// The discard path of this ``ContentKind`` releases it.
    case kind(ContentKind)
    /// The terminal warm set closes it when it falls out of the set (``WarmSetRelease`` under memory pressure, the warm set LRU otherwise).
    case warmSet
    /// Nothing releases it while its tab is open.
    case never(why: String)
}

/// What a pane's tab shows: the App's `TabContent` cases without their payloads (`TabContent.contentClass`
/// maps each case). Chrome decides every tab's discard eligibility in one place
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc); each class declares
/// its row in ``discard``, an exhaustive switch, so a new class does not compile without one.
package nonisolated enum TabContentClass: String, CaseIterable, Hashable, Sendable {
    case terminal, browser, agent, page, placeholder, notice, conversation

    /// How this class's hidden content is released.
    package var discard: TabContentDiscard {
        switch self {
        case .terminal: .warmSet
        case .browser: .kind(.browser)
        case .agent: .kind(.agentPage)
        case .page: .kind(.internalPage)
        case .placeholder: .never(why: "a label over a remote terminal that is not attached; it holds no surface")
        case .notice: .never(why: "one line naming the Mac whose acpmux runs the chat; it holds no page")
        case .conversation:
            .never(why: "the native transcript keeps its laid-out rows until task p07-memory-030 releases them")
        }
    }
}
