import AppKit
import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21, on the web-ota row's card (a chat icon and the name, a folder line "leoli", a
/// truncated last message): "this doesn't line up nor work very well". A home folder is no fact;
/// the place reads as the repository and branch when known; the last line says where the
/// workspace stands (it needs you, its pull request's state in color) before the raw last reply.
@MainActor struct WorkspaceHoverCardPreviewTests {
    private static let home = "/Users/leoli"

    private static func chat(_ change: (inout SidebarWorkspace) -> Void = { _ in }) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-web-ota"), title: "web-ota", directory: "~", kind: .harness)
        workspace.lastMessage = "I updated the OTA manifest and the release notes; the next step is to run the upload."
        change(&workspace)
        return workspace
    }

    private static func card(_ workspace: SidebarWorkspace, pullRequests: SidebarPullRequestBadge? = nil,
                             options: WorkspaceHoverCardOptions? = nil, timeline: [SidebarTimelineEntry] = []) -> WorkspaceHoverCardContent {
        if let options {
            return WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date(), options: options, timeline: timeline,
                                                  pullRequests: pullRequests, home: home)
        }
        return WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date(), pullRequests: pullRequests, home: home)
    }

    private static func badge(_ items: [SidebarPullRequestItem]) -> SidebarPullRequestBadge? {
        SidebarPullRequestBadge.combining(items: items)
    }

    private static func item(_ number: Int, _ state: SidebarPullRequestItem.State, repository: String = "manaflow-ai/cmux",
                             createdAt: String) -> SidebarPullRequestItem {
        SidebarPullRequestItem(url: "https://github.com/\(repository)/pull/\(number)", repository: repository, number: number,
                               title: "Polish the workspace card", state: state, additions: 120, deletions: 30, createdAt: createdAt)
    }

    // MARK: The home folder is no fact

    @Test(arguments: ["~", "~/", "/Users/leoli", "/Users/leoli/", "/Users/leoli/.", "/home/ubuntu", "/Users/other", "/root", "/", "", "  "])
    func aHomeFolderSaysNothing(_ directory: String) {
        #expect(WorkspaceHoverCardContent.meaningfulFolder(directory, home: Self.home) == nil, "\(directory)")
    }

    @Test func noFolderSaysNothing() {
        #expect(WorkspaceHoverCardContent.meaningfulFolder(nil, home: Self.home) == nil)
    }

    @Test(arguments: [("~/code/cmux", "cmux"), ("/Users/leoli/Projects", "Projects"), ("~/Projects/web-ota/", "web-ota"),
                      ("/home/ubuntu/src/app", "app"), ("/tmp", "tmp")])
    func aRealFolderReadsAsItsName(_ directory: String, _ name: String) {
        #expect(WorkspaceHoverCardContent.meaningfulFolder(directory, home: Self.home) == name)
    }

    @Test func theWebOtaCardHasNoLeoliLine() {
        let card = Self.card(Self.chat())
        #expect(!card.facts.contains { $0.kind == "folder" })
        #expect(!card.facts.contains { $0.text == "leoli" || $0.text == "~" })
        #expect(card.facts.map(\.kind) == [WorkspaceHoverCardContent.Fact.lastReplyKind])
    }

    @Test func theAbsoluteHomeFolderIsDroppedToo() {
        let card = Self.card(Self.chat { $0.directory = Self.home })
        #expect(!card.facts.contains { $0.kind == "folder" })
    }

    // MARK: The repository and branch

    @Test func aCheckoutReadsAsItsRepositoryAndBranch() throws {
        let card = Self.card(Self.chat { $0.directory = "~/code/cmux"; $0.branch = "feat-cmux-next" })
        let place = try #require(card.facts.first { $0.kind == "branch" })
        #expect(place.text == "cmux · feat-cmux-next")
        #expect(place.icon == .gitBranch)
        #expect(!card.facts.contains { $0.kind == "folder" }, "one line, not a folder line and a branch line")
    }

    @Test func thePullRequestNamesTheRepository() throws {
        let badge = Self.badge([Self.item(7, .passing, repository: "manaflow-ai/cmux-next", createdAt: "2026-10-21T10:00:00Z")])
        let card = Self.card(Self.chat { $0.directory = "~/wt/lane-7"; $0.branch = "fix/card" }, pullRequests: badge)
        #expect(card.facts.first { $0.kind == "branch" }?.text == "cmux-next · fix/card")
    }

    @Test(arguments: [("~/wt/glass-regressions--hover-card-polish", "glass-regressions/hover-card-polish"),
                      ("~/wt/lane--fix-card", "lane/fix-card"), ("~/code/Fix_Card", "fix-card")])
    func aWorktreeNamedAfterItsBranchReadsAsTheBranch(_ directory: String, _ branch: String) {
        let card = Self.card(Self.chat { $0.directory = directory; $0.branch = branch })
        #expect(card.facts.first { $0.kind == "branch" }?.text == branch)
    }

    @Test func portsNeverLandUnderThePreview() throws {
        let badge = Self.badge([Self.item(9, .passing, createdAt: "2026-10-21T10:00:00Z")])
        var options = WorkspaceHoverCardOptions()
        options.layout = .classic
        let card = Self.card(Self.chat { $0.ports = ":3000"; $0.branch = "main"; $0.directory = "~/code/site" },
                             pullRequests: badge, options: options)
        #expect(card.facts.contains { $0.kind == "ports" })
        #expect(try #require(card.facts.last).isPreview, "kinds: \(card.facts.map(\.kind))")
    }

    @Test func aBranchInTheHomeFolderReadsAsTheBranch() {
        let card = Self.card(Self.chat { $0.branch = "main" })
        #expect(card.facts.first { $0.kind == "branch" }?.text == "main")
        #expect(!card.facts.contains { $0.kind == "folder" })
    }

    @Test func aFolderOffABranchReadsAsTheFolder() {
        let card = Self.card(Self.chat { $0.directory = "~/Downloads" })
        #expect(card.facts.first { $0.kind == "folder" }?.text == "Downloads")
    }

    @Test func withGitHiddenThePlaceIsTheFolderAlone() {
        var options = WorkspaceHoverCardOptions()
        options.layout = .classic
        options.showsGit = false
        let card = Self.card(Self.chat { $0.directory = "~/code/cmux"; $0.branch = "main" }, options: options)
        #expect(card.facts.first { $0.kind == "folder" }?.text == "cmux")
        #expect(!card.facts.contains { $0.kind == "branch" || $0.kind == "pullRequest" })
    }

    // MARK: The preview: the latest status, else the last reply

    /// A folder that only matches the branch's last part is an ordinary repository, not a worktree.
    @Test(arguments: [("~/code/card", "feature/card", "card · feature/card"),
                      ("~/code/cmux", "lane/cmux", "cmux · lane/cmux")])
    func aRepositoryNamedLikeItsBranchTailKeepsItsName(_ directory: String, _ branch: String, _ text: String) {
        let card = Self.card(Self.chat { $0.directory = directory; $0.branch = branch })
        #expect(card.facts.first { $0.kind == "branch" }?.text == text)
    }

    @Test func withNoStatusThePreviewIsTheLastReply() throws {
        let workspace = Self.chat()
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: nil) == .message(try #require(workspace.lastMessage)))
        let last = try #require(Self.card(workspace).facts.last)
        #expect(last.kind == WorkspaceHoverCardContent.Fact.lastReplyKind && last.isPreview && last.lines == 2)
    }

    @Test func aWaitWinsOverTheLastReply() {
        let reason = Self.chat { $0.detail.needsInput = "Allow Bash: rm -rf build?" }
        #expect(WorkspaceHoverCardContent.preview(reason, pullRequests: nil) == .needsYou)
        let card = Self.card(reason)
        #expect(!card.facts.contains { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind })
        #expect(card.facts.first?.kind == "needsInput")
        #expect(card.facts.first?.iconTone == .attention)

        // A wait with no reason: the waiting status row says so, so no reply shows under it.
        let waiting = Self.chat { $0.activity = .waiting(kind: nil) }
        #expect(WorkspaceHoverCardContent.preview(waiting, pullRequests: nil) == .needsYou)
        #expect(!Self.card(waiting).facts.contains { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind || $0.isPreview })

        // A chip that needs the person, with no reason and no waiting status row: the preview says
        // so, in the wait's color, with or without a reply.
        for message in [nil, Self.chat().lastMessage] {
            let chip = Self.chat { $0.agentChip = .needsYou; $0.lastMessage = message }
            #expect(WorkspaceHoverCardContent.preview(chip, pullRequests: nil) == .needsYou)
            let card = Self.card(chip)
            let last = card.facts.last
            #expect(last?.kind == WorkspaceHoverCardContent.needsYouKind && last?.iconTone == .attention && last?.isPreview == true)
            #expect(last?.ink == .attention && last?.text == CmuxNextSidebar.Strings.priorityNeedsYou)
            #expect(!card.facts.contains { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind }, "reply: \(message ?? "none")")
        }
        // With a reason or a waiting status row, it is said already: no second line.
        #expect(!Self.card(reason).facts.contains { $0.kind == WorkspaceHoverCardContent.needsYouKind })
        #expect(!Self.card(waiting).facts.contains { $0.kind == WorkspaceHoverCardContent.needsYouKind })
        #expect(!Self.card(Self.chat { $0.activity = .waiting(kind: nil); $0.lastMessage = nil }).facts
            .contains { $0.kind == WorkspaceHoverCardContent.needsYouKind })
    }

    /// Every layout keeps a needs-you chip's "Needs you" line as its last, never the raw reply,
    /// including the history-only log and the one-line minimal card.
    @Test(arguments: WorkspaceHoverCardOptions.Layout.allCases)
    func eachLayoutKeepsNeedsYou(_ layout: WorkspaceHoverCardOptions.Layout) {
        var options = WorkspaceHoverCardOptions()
        options.layout = layout
        let prompt = SidebarTimelineEntry(kind: .prompt, date: Date(), text: "Ship the OTA build")
        let card = Self.card(Self.chat { $0.agentChip = .needsYou }, options: options, timeline: [prompt])
        let last = card.facts.last
        #expect(last?.kind == WorkspaceHoverCardContent.needsYouKind && last?.text == CmuxNextSidebar.Strings.priorityNeedsYou,
                "kinds: \(card.facts.map(\.kind))")
        #expect(card.facts.filter { $0.kind == WorkspaceHoverCardContent.needsYouKind }.count == 1)
        #expect(!card.facts.contains { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind })
        if layout == .minimal { #expect(card.facts.map(\.kind) == ["task", WorkspaceHoverCardContent.needsYouKind]) }
    }

    /// A blank needs-input reason is no reason: no empty row, and the last reply still shows.
    @Test(arguments: ["", "  ", "\n"])
    func aBlankReasonIsNoWait(_ reason: String) throws {
        let workspace = Self.chat { $0.detail.needsInput = reason }
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: nil) == .message(try #require(workspace.lastMessage)))
        let card = Self.card(workspace)
        #expect(!card.facts.contains { $0.kind == "needsInput" })
        #expect(card.facts.last?.kind == WorkspaceHoverCardContent.Fact.lastReplyKind)
    }

    @Test func aWaitWinsOverAPullRequest() {
        let badge = Self.badge([Self.item(1, .passing, createdAt: "2026-10-21T10:00:00Z")])
        let workspace = Self.chat { $0.detail.needsInput = "Approve the plan?" }
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: badge) == .needsYou)
    }

    @Test(arguments: [(SidebarPullRequestItem.State.merged, HoverCardTone.merged), (.passing, .success), (.failing, .danger),
                      (.conflict, .attention), (.draft, .attention)])
    func aPullRequestIsThePreviewInItsColor(_ state: SidebarPullRequestItem.State, _ tone: HoverCardTone) throws {
        let badge = Self.badge([Self.item(23729, state, createdAt: "2026-10-21T10:00:00Z")])
        let workspace = Self.chat()
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: badge) == .pullRequest)
        let card = Self.card(workspace, pullRequests: badge)
        let last = try #require(card.facts.last)
        #expect(last.kind == "pullRequest" && last.isPreview)
        #expect(last.iconTone == tone && last.statusTone == tone)
        #expect(last.status == CmuxNextSidebar.Strings.pullRequestState(state))
        #expect(last.text == "#23729 Polish the workspace card")
        #expect(last.additions == 120 && last.deletions == 30)
        #expect(!card.facts.contains { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind }, "the status, not the raw reply")
        #expect(card.facts.filter { $0.kind == "pullRequest" }.count == 1)
    }

    @Test func aPullRequestCutsAtItsTailAndAPlaceInTheMiddle() {
        typealias Fact = WorkspaceHoverCardContent.Fact
        #expect(WorkspaceHoverCardView.truncation(Fact(icon: .gitPullrequest, text: "#1 A long title", kind: "pullRequest"))
            == .byTruncatingTail)
        #expect(WorkspaceHoverCardView.truncation(Fact(icon: .gitBranch, text: "cmux · feat/a-long-branch", kind: "branch"))
            == .byTruncatingMiddle)
    }

    @Test func theNewestOpenPullRequestIsNamed() {
        let badge = Self.badge([Self.item(1, .merged, createdAt: "2026-10-20T10:00:00Z"),
                                Self.item(2, .closed, createdAt: "2026-10-21T12:00:00Z"),
                                Self.item(3, .failing, createdAt: "2026-10-21T10:00:00Z")])
        #expect(WorkspaceHoverCardContent.newestPullRequest(badge)?.number == 3, "the newest one that is not closed")
    }

    @Test func aHooksPullRequestEntryCountsAsAStatus() throws {
        let workspace = Self.chat { $0.pullRequest = "#42 ✓" }
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: nil) == .pullRequest)
        let last = try #require(Self.card(workspace).facts.last)
        #expect(last.kind == "pullRequest" && last.text == "#42 ✓" && last.isPreview)
    }

    @Test func withGitHiddenAPullRequestIsNoPreview() throws {
        let badge = Self.badge([Self.item(5, .passing, createdAt: "2026-10-21T10:00:00Z")])
        let workspace = Self.chat()
        #expect(WorkspaceHoverCardContent.preview(workspace, pullRequests: badge, showsGit: false)
            == .message(try #require(workspace.lastMessage)))
    }

    @Test func aTaskOrNothingLeavesNoPreview() {
        #expect(WorkspaceHoverCardContent.preview(Self.chat { $0.detail.task = "Ship the OTA" }, pullRequests: nil) == .empty)
        #expect(WorkspaceHoverCardContent.preview(Self.chat { $0.lastMessage = "  " }, pullRequests: nil) == .empty)
        #expect(Self.card(Self.chat { $0.lastMessage = nil }).facts.isEmpty)
    }
}
