import CmuxNextHibernation

/// How a tab's hidden content is released (p07-memory.md DC4, MQ-CONTENT). Chrome decides every
/// tab's discard eligibility in one place
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc); each `TabContent`
/// case declares its row in ``TabContent/Case/discard``, and the compiler asks for a row for a new case.
nonisolated enum TabContentDiscard: Hashable, Sendable {
    /// The discard path of this ``ContentKind`` releases it.
    case kind(ContentKind)
    /// The terminal warm set closes it when it falls out of the set (`TabContentCache.setWarmBudget`).
    case warmSet
    /// Nothing releases it while its tab is open.
    case never(why: String)
}

extension TabContent {
    /// The cases of `TabContent` without their payloads.
    nonisolated enum Case: String, CaseIterable, Hashable, Sendable {
        case terminal, browser, agent, page, placeholder, notice, conversation

        /// How this case's hidden content is released.
        var discard: TabContentDiscard {
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

    /// This content's case.
    var contentCase: Case {
        switch self {
        case .terminal: .terminal
        case .browser: .browser
        case .agent: .agent
        case .page: .page
        case .placeholder: .placeholder
        case .notice: .notice
        case .conversation: .conversation
        }
    }
}
