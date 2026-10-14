@testable import CmuxNextApp
import Testing

/// A workspace the user never named takes its front tab's name (hq#1957):
/// a browser its page title, an agent chat its chat title, a terminal its
/// live title or folder. A user's name always wins, `workspaces.autoName`
/// off names nothing, and the `persist` variant renames a workspace once.
struct WorkspaceAutoNameTests {
    private static let live = WorkspaceAutoName(enabled: true, variant: .live)
    private static let persist = WorkspaceAutoName(enabled: true, variant: .persist)

    private static func terminal(title: String? = nil, cwd: String? = nil, userName: String? = nil) -> WorkspaceAutoName.Front {
        .terminal(NewWorkspaceName.Tab(kind: .terminal, userName: userName, title: title, pageTitle: nil, url: nil, cwd: cwd))
    }

    // MARK: Label (both variants)

    @Test func browserFrontTabShowsItsPageTitle() {
        let front = WorkspaceAutoName.Front.browser(title: "Pull requests · cmux", offTheRecord: false)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "Pull requests · cmux")
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

    @Test func terminalShowsItsLiveTitle() {
        let front = Self.terminal(title: "npm run dev", cwd: "/Users/me/src/cmux")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: front) == "npm run dev")
    }

    @Test func terminalWithABareShellTitleShowsItsFolder() {
        #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: "zsh", cwd: "/Users/me/src/cmux")) == "cmux")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: Self.terminal(title: "-bash", cwd: "/tmp/api")) == "api")
    }

    @Test func multiLineAndLongNamesAreTrimmedToOneLine() {
        let long = String(repeating: "a", count: 200)
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: "one\ntwo")) == "one two")
        #expect(Self.live.label(name: "workspace-3", title: nil, front: .chat(userName: nil, title: long))?.count == NewWorkspaceName.maxLength)
    }

    @Test func userNamedWorkspaceKeepsItsName() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.live.label(name: "api", title: nil, front: front) == nil)
        #expect(Self.live.label(name: "workspace-3", title: "My work", front: front) == nil)
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

    // MARK: Persist (variant B): rename once, never a user-named workspace

    @Test func persistRenamesADefaultNamedWorkspaceOnceItsNameIsAvailable() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.persist.persistedName(name: "workspace-3", title: nil, front: front, alreadyRenamed: false) == "Fix the sidebar drag")
    }

    @Test func persistWaitsWhileNoNameIsAvailable() {
        #expect(Self.persist.persistedName(name: "workspace-3", title: nil, front: .chat(userName: nil, title: nil), alreadyRenamed: false) == nil)
        #expect(Self.persist.persistedName(name: "workspace-3", title: nil, front: nil, alreadyRenamed: false) == nil)
    }

    @Test func persistNeverRenamesTwice() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "A new topic")
        #expect(Self.persist.persistedName(name: "workspace-3", title: nil, front: front, alreadyRenamed: true) == nil)
    }

    @Test func persistNeverRenamesAUserNamedWorkspace() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Fix the sidebar drag")
        #expect(Self.persist.persistedName(name: "api", title: nil, front: front, alreadyRenamed: false) == nil)
        #expect(Self.persist.persistedName(name: "workspace-3", title: "Mine", front: front, alreadyRenamed: false) == nil)
    }

    @Test func persistNeverWritesAnIncognitoPageTitle() {
        let front = WorkspaceAutoName.Front.browser(title: "Secret", offTheRecord: true)
        #expect(Self.persist.persistedName(name: "workspace-3", title: nil, front: front, alreadyRenamed: false) == nil)
    }

    @Test func liveVariantAndSettingOffNeverRename() {
        let front = WorkspaceAutoName.Front.chat(userName: nil, title: "Plan")
        #expect(Self.live.persistedName(name: "workspace-3", title: nil, front: front, alreadyRenamed: false) == nil)
        let off = WorkspaceAutoName(enabled: false, variant: .persist)
        #expect(off.persistedName(name: "workspace-3", title: nil, front: front, alreadyRenamed: false) == nil)
    }

    @Test func persistNamesATerminalWorkspaceByItsFolder() {
        let front = Self.terminal(title: "zsh", cwd: "/Users/me/src/cmux")
        #expect(Self.persist.persistedName(name: "workspace-12", title: nil, front: front, alreadyRenamed: false) == "cmux")
    }
}
