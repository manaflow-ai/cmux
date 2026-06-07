import Foundation

/// Settings under the dotted-id prefix `terminal.*`.
public struct TerminalCatalogSection: SettingCatalogSection {
    public let showScrollBar = DefaultsKey<Bool>(
        id: "terminal.showScrollBar",
        defaultValue: true,
        userDefaultsKey: "terminal.showScrollBar"
    )

    public let copyOnSelect = DefaultsKey<Bool>(
        id: "terminal.copyOnSelect",
        defaultValue: false,
        userDefaultsKey: "terminal.copyOnSelect"
    )

    public let autoResumeAgentSessions = DefaultsKey<Bool>(
        id: "terminal.autoResumeAgentSessions",
        defaultValue: true,
        userDefaultsKey: "terminal.autoResumeAgentSessions"
    )

    public let agentHibernationEnabled = DefaultsKey<Bool>(
        id: "terminal.agentHibernation.enabled",
        defaultValue: false,
        userDefaultsKey: "terminal.agentHibernation.enabled"
    )

    public let agentHibernationIdleSeconds = DefaultsKey<Double>(
        id: "terminal.agentHibernation.idleSeconds",
        defaultValue: 5,
        userDefaultsKey: "terminal.agentHibernation.idleSeconds"
    )

    public let agentHibernationMaxLiveTerminals = DefaultsKey<Int>(
        id: "terminal.agentHibernation.maxLiveTerminals",
        defaultValue: 12,
        userDefaultsKey: "terminal.agentHibernation.maxLiveTerminals"
    )

    public let showTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.showTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.showTextBoxOnNewTerminals"
    )

    public let focusTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.focusTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.focusTextBoxOnNewTerminals"
    )

    public let textBoxMaxLines = DefaultsKey<Int>(
        id: "terminal.textBoxMaxLines",
        defaultValue: 10,
        userDefaultsKey: "terminal.textBoxMaxLines"
    )

    public let resumeCommands = JSONKey<[String]>(
        id: "terminal.resumeCommands",
        defaultValue: []
    )

    public init() {}
}
