import CmuxNextDaemon
@testable import CmuxNextWorkspaceNaming
import Testing

/// A workspace the user never named takes its front tab's name (hq#1957):
/// a browser its page title, an agent chat its chat title, a terminal its
/// live title or folder. A user's name always wins, `workspaces.autoName`
/// off names nothing, and the `persist` variant renames a workspace once.
struct WorkspaceAutoNameTests {
    private static let live = WorkspaceAutoName(enabled: true, variant: .live)
    private static let persist = WorkspaceAutoName(enabled: true, variant: .persist)

    @Test func theDefaultVariantPersistsTheFirstChatTitle() {
        #expect(WorkspaceAutoNameTunables.variant.defaultValue == .persist)
    }

    private static func terminal(title: String? = nil, cwd: String? = nil, userName: String? = nil) -> WorkspaceAutoName.Front {
        .terminal(NewWorkspaceName.Tab(kind: .terminal, userName: userName, title: title, pageTitle: nil, url: nil, cwd: cwd))
    }

    // MARK: Label (both variants)

    @Test func browserFrontTabShowsItsPageTitle() {
        let front = WorkspaceAutoName.Front.browser(title: "Pull requests · cmux", offTheRecord: false)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "Pull requests · cmux")
    }

    @Test func browserSplitBesideAChatKeepsTheChatsName() {
        let page = WorkspaceAutoName.Front.browser(title: "browser.md: Widevine and H.264/AAC ship", offTheRecord: false)
        let chat = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix image paste")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: page, anchor: chat) == "Fix image paste")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: page, anchor: Self.terminal(title: "zsh", cwd: "/tmp/api")) == "api")
    }

    @Test func browserSplitBesideAnUntitledChatShowsNoPageTitle() {
        let page = WorkspaceAutoName.Front.browser(title: "Pull requests · cmux", offTheRecord: false)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: page, anchor: .chat(userName: nil, title: nil)) == nil)
    }

    @Test func browserSplitNeverRenamesAUserNamedWorkspace() {
        let page = WorkspaceAutoName.Front.browser(title: "Pull requests · cmux", offTheRecord: false)
        #expect(Self.live.label(name: "#20367: CI red", title: nil, front: page, anchor: nil, nameSource: .user) == nil)
        #expect(Self.live.label(name: "workspace-3", title: "Mine", front: page, anchor: nil) == nil)
    }

    @Test func titledChatShowsItsChatTitle() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "Fix the sidebar drag")
    }

    @Test func chatTabTheUserNamedShowsThatName() {
        let front = WorkspaceAutoName.Front.chat(userName: "Release notes", title: "Draft the changelog")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "Release notes")
    }

    @Test func untitledChatIsSkipped() {
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: nil)) == nil)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: "  ", title: "\n")) == nil)
    }

    /// An agent's spinner frames (`⠐ Fix the login bug`) name the workspace by their words only
    /// (plans/cmux-next/osc-titles.md), so the row does not change on every frame.
    @Test func terminalTitleLosesItsStatusGlyphs() {
        for raw in ["⠂ Fix the login bug", "⠐ Fix the login bug", "✳ Fix the login bug"] {
            #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: raw)) == "Fix the login bug")
        }
        #expect(Self.live.label(name: "Release", title: nil, front: Self.terminal(title: "⠂ Fix the login bug"), nameSource: .user) == nil)
    }

    @Test func terminalShowsItsLiveTitle() {
        let front = Self.terminal(title: "npm run dev", cwd: "/Users/me/src/cmux")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "npm run dev")
    }

    @Test func terminalWithABareShellTitleShowsItsFolder() {
        #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: "zsh", cwd: "/Users/me/src/cmux")) == "cmux")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: "-bash", cwd: "/tmp/api")) == "api")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: "~", cwd: "/tmp/api")) == "api")
    }

    @Test func multiLineAndLongNamesAreTrimmedToOneLine() {
        let long = String(repeating: "a", count: 200)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: "one\ntwo")) == "one two")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: long))?.count == NewWorkspaceName.maxLength)
    }

    @Test func userNamedWorkspaceKeepsItsName() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.live.label(name: "api", title: nil, front: front, nameSource: .user) == nil)
        #expect(Self.live.label(name: "workspace-3", title: "My work", front: front) == nil)
    }

    @Test func legacyDefaultNamesStillTakeAFrontTabName() {
        let front = Self.terminal(title: "npm run dev")
        #expect(Self.live.label(name: "~", title: nil, front: front) == "npm run dev")
        #expect(Self.live.label(name: "", title: nil, front: front) == "npm run dev")
        #expect(Self.live.label(name: "~", title: "My work", front: front) == nil)
        #expect(Self.live.label(name: "~", title: nil, front: front, nameSource: .user, nameRevision: 1) == nil)
        #expect(Self.live.label(name: "~", title: nil, front: front, nameSource: .user, nameRevision: 0,
                                allowsLegacyDefaults: false) == nil)
    }

    @Test func emptyTitleDoesNotCountAsAUserName() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.live.label(name: "workspace-3", title: "", front: front) == "Fix the sidebar drag")
    }

    @Test func noFrontTabNamesNothing() {
        #expect(Self.live.label(name: "workspace-3", title: nil, front: nil) == nil)
    }

    @Test func settingOffNamesNothing() {
        let off = WorkspaceAutoName(enabled: false, variant: .live)
        #expect(off.label(name: "workspace-3", title: nil, front: .browser(title: "GitHub", offTheRecord: false)) == nil)
        #expect(off.label(name: "workspace-3", title: nil, front: Self.terminal(title: "npm run dev")) == nil)
        let offPersist = WorkspaceAutoName(enabled: false, variant: .persist)
        #expect(offPersist.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: "Plan")) == nil)
    }

    @Test func persistVariantStillShowsTheLabelUntilTheRenameLands() {
        #expect(Self.persist.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: "Plan")) == "Plan")
    }

    @Test func incognitoPageShowsItsTitleInTheRow() {
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .browser(title: "Secret", offTheRecord: true)) == "Secret")
    }

    // MARK: Persist (variant B): only a generated chat title, once, on this Mac, never a user-named workspace

    private static func persisted(_ front: WorkspaceAutoName.Front?, name: String = "workspace-3", title: String? = nil,
                                  local: Bool = true, supportsNameSource: Bool = false, alreadyRenamed: Bool = false,
                                  nameSource: WorkspaceNameSource = .auto, nameRevision: UInt64 = 0,
                                  rule: WorkspaceAutoName = persist) -> String? {
        rule.persistedName(name: name, title: title, front: front, isLocalMachine: local,
                           supportsNameSource: supportsNameSource, alreadyRenamed: alreadyRenamed,
                           nameSource: nameSource, nameRevision: nameRevision)
    }

    private static let titledChat = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag", generatedTitle: "Fix the sidebar drag")

    @Test func persistRenamesOnceAChatHasAGeneratedTitle() {
        #expect(Self.persisted(Self.titledChat) == "Fix the sidebar drag")
        #expect(Self.persisted(Self.titledChat, alreadyRenamed: true) == nil)
    }

    @Test func persistNeverWritesAChatsFirstPrompt() {
        // The chat's title is only its first prompt (`AgentTurnStates.title`'s fallback): the row shows it, nothing is written.
        let promptOnly = WorkspaceAutoName.Front.chat(userName: nil, title: "can you look at why the build fails", generatedTitle: nil)
        #expect(Self.persisted(promptOnly) == nil)
        #expect(Self.persist.label(name: "workspace-3", title: nil, front: promptOnly) == "can you look at why the build fails")
    }

    @Test func persistNeverWritesTheTabsOwnName() {
        #expect(Self.persisted(.chat(userName: "Release notes", title: "Draft", generatedTitle: nil)) == nil)
    }

    @Test func persistWaitsWhileNoNameIsAvailable() {
        #expect(Self.persisted(.chat(userName: nil, title: nil)) == nil)
        #expect(Self.persisted(nil) == nil)
    }

    @Test func persistNeverRenamesFromATerminalOrBrowser() {
        #expect(Self.persisted(Self.terminal(title: "zsh", cwd: "/Users/me/src/cmux")) == nil)
        #expect(Self.persisted(Self.terminal(title: "vim notes.md")) == nil)
        #expect(Self.persisted(.browser(title: "GitHub", offTheRecord: false)) == nil)
        #expect(Self.persisted(.browser(title: "Secret", offTheRecord: true)) == nil)
    }

    @Test func persistFollowsAnAutomaticWorkspaceAndSkipsTheCurrentTitle() {
        #expect(Self.persisted(Self.titledChat, name: "Old generated title", nameSource: .auto) == "Fix the sidebar drag")
        #expect(Self.persisted(Self.titledChat, name: "Fix the sidebar drag", nameSource: .auto) == nil)
    }

    @Test func persistNeverRenamesAUserNamedOrTitledWorkspace() {
        #expect(Self.persisted(Self.titledChat, name: "api", nameSource: .user, nameRevision: 1) == nil)
        #expect(Self.persisted(Self.titledChat, title: "Mine") == nil)
    }

    /// A workspace created under the default name the app showed (`workspace-N`, never renamed) is
    /// unnamed even when the daemon recorded that name as requested (#26680).
    @Test func aCreatedDefaultNameRecordedAsTheUsersIsStillUnnamed() {
        #expect(!WorkspaceAutoName.isUserNamed(name: "workspace-151", title: nil, nameSource: .user, nameRevision: 0,
                                               allowsLegacyDefaults: false))
        #expect(Self.persisted(Self.titledChat, name: "workspace-151", supportsNameSource: true,
                               nameSource: .user, nameRevision: 0) == "Fix the sidebar drag")
        #expect(Self.live.label(name: "workspace-151", title: nil, front: Self.titledChat, nameSource: .user,
                                nameRevision: 0, allowsLegacyDefaults: false) == "Fix the sidebar drag")
        // A person's rename (revision 1), a home marker and any other name stay theirs.
        #expect(WorkspaceAutoName.isUserNamed(name: "workspace-151", title: nil, nameSource: .user, nameRevision: 1,
                                              allowsLegacyDefaults: false))
        #expect(WorkspaceAutoName.isUserNamed(name: "~", title: nil, nameSource: .user, nameRevision: 0,
                                              allowsLegacyDefaults: false))
        #expect(WorkspaceAutoName.isUserNamed(name: "api", title: nil, nameSource: .user, nameRevision: 0,
                                              allowsLegacyDefaults: false))
        // The daemon matches `workspace-N` exactly; a padded one is the person's and stays pinned.
        #expect(WorkspaceAutoName.isUserNamed(name: " workspace-151 ", title: nil, nameSource: .user, nameRevision: 0,
                                              allowsLegacyDefaults: false))
    }

    @Test func persistNamesARemoteWorkspaceWhenTheDaemonSupportsNameSource() {
        #expect(Self.persisted(Self.titledChat, local: false, supportsNameSource: true) == "Fix the sidebar drag")
    }

    @Test func persistSkipsAnOlderRemoteDaemonWithoutNameSource() {
        #expect(Self.persisted(Self.titledChat, local: false) == nil)
    }

    @Test func liveVariantAndSettingOffNeverRename() {
        #expect(Self.persisted(Self.titledChat, rule: Self.live) == nil)
        #expect(Self.persisted(Self.titledChat, rule: WorkspaceAutoName(enabled: false, variant: .persist)) == nil)
    }

    @Test func aRenameIsDroppedWhenTheUserNamedTheWorkspaceMeanwhile() {
        #expect(Self.persist.confirmsRename(currentName: "workspace-3", currentTitle: nil))
        #expect(Self.persist.confirmsRename(currentName: "workspace-3", currentTitle: ""))
        #expect(!Self.persist.confirmsRename(currentName: "api", currentTitle: nil, nameSource: .user))
        #expect(!Self.persist.confirmsRename(currentName: "workspace-3", currentTitle: "Mine"))
        #expect(!Self.persist.confirmsRename(currentName: "~", currentTitle: nil, nameSource: .user, nameRevision: 1))
    }
}
