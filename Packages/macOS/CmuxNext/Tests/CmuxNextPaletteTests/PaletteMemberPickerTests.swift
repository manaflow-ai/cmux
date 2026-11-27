import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// New Group Chat in Cmd-Shift-P lists the people and Chiefs who can join, instead of a blank
/// comma-separated field (user, Oct 30: "new group chat should prefill members that can join").
/// Return on a row adds it as a chip and keeps the list open; Return on Continue sends the
/// chosen ids, comma-joined, as `members` (what `cmux chat create --members` takes).
@MainActor
@Suite
struct PaletteMemberPickerTests {
    private static func flow(_ registry: ActionRegistry) throws -> PaletteArgumentFlow {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "home.createGroup" })
        return PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: nil)
    }

    private static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.homeMembers
                ? [ActionEnumCase(value: "chief_1", title: "Chief"), ActionEnumCase(value: "user_aziz", title: "Aziz"),
                   ActionEnumCase(value: "user_leo", title: "Leo")]
                : []
        }
        return registry
    }

    private static func page(_ effect: PaletteEffect) throws -> PalettePageSpec {
        switch effect.resolved() {
        case .push(let page), .replace(let page): return page
        default:
            Issue.record("expected a list page, got another step")
            throw PickerError.notAList
        }
    }

    private enum PickerError: Error { case notAList, noRow }

    private static func items(_ page: PalettePageSpec) throws -> [PaletteItem] {
        try #require(page.providers.first as? StaticPaletteProvider).itemsList
    }

    private static func choose(_ title: String, on page: PalettePageSpec) throws -> PaletteEffect {
        guard let item = try items(page).first(where: { $0.title == title }) else { throw PickerError.noRow }
        return item.primary.effect
    }

    @Test func newGroupChatListsWhoCanJoin() throws {
        let page = try Self.page(try Self.flow(Self.registry()).effect(collected: ActionInvocation()))
        #expect(try Self.items(page).map(\.title) == ["Chief", "Aziz", "Leo"])
        #expect(page.tokens.isEmpty)
    }

    @Test func choosingAMemberAddsAChipAndKeepsTheListOpen() throws {
        let first = try Self.page(try Self.flow(Self.registry()).effect(collected: ActionInvocation()))
        let effect = try Self.choose("Aziz", on: first)
        guard case .replace(let second) = effect.resolved() else {
            Issue.record("choosing a member closed or left the list")
            return
        }
        #expect(second.tokens.map(\.title) == ["Aziz"])
        let rows = try Self.items(second)
        #expect(rows.first?.id == PaletteArgumentFlow.continueRowID)
        #expect(rows.first { $0.title == "Aziz" }?.accessory == PaletteStrings.added)
        // The chip's remove (a click, or Backspace on an empty query) shows the list without it.
        let removed = try #require(second.tokens.first?.remove())
        #expect(removed.tokens.isEmpty)
    }

    @Test func continueHeadingIsTheActionNameWithoutAnEllipsis() throws {
        let first = try Self.page(try Self.flow(Self.registry()).effect(collected: ActionInvocation()))
        let page = try Self.page(try Self.choose("Aziz", on: first))
        let row = try #require(try Self.items(page).first { $0.id == PaletteArgumentFlow.continueRowID })
        #expect(row.section.title == "New Group Chat")
    }

    /// Every locale's "New Group Chat…" loses its ellipsis and the space some put before it.
    @Test(arguments: [
        "New Group Chat…",
        "دردشة جماعية جديدة…",
        "Novi grupni chat…",
        "Ny gruppechat…",
        "Neuer Gruppenchat …",
        "Nuevo chat de grupo…",
        "Nouvelle discussion de groupe…",
        "Nuova chat di gruppo…",
        "新規グループチャット…",
        "ការជជែកជាក្រុមថ្មី…",
        "새 그룹 채팅…",
        "Ny gruppechat …",
        "Nowy czat grupowy…",
        "Novo chat em grupo…",
        "Новый групповой чат…",
        "แชทกลุ่มใหม่…",
        "Yeni Grup Sohbeti…",
        "Новий груповий чат…",
        "Cuộc trò chuyện nhóm mới…",
        "新建群聊…",
        "新增群組聊天…"
    ])
    func headingDropsTheEllipsisInEveryLocale(_ title: String) {
        let base = PaletteArgumentFlow.baseTitle(title)
        #expect(!base.hasSuffix("…") && !base.hasSuffix(" ") && !base.isEmpty)
        #expect(title.hasPrefix(base))
    }

    @Test func baseTitleKeepsTitlesWithoutAnEllipsis() {
        #expect(PaletteArgumentFlow.baseTitle("Rename Tab...") == "Rename Tab")
        #expect(PaletteArgumentFlow.baseTitle("Close Tab") == "Close Tab")
        #expect(PaletteArgumentFlow.baseTitle("…") == "…")
    }

    @Test func continueSendsTheChosenIdsAsMembers() throws {
        let registry = Self.registry()
        var ran: ActionInvocation?
        registry.bind("home.createGroup", invoke: { ran = $0 })
        var page = try Self.page(try Self.flow(registry).effect(collected: ActionInvocation()))
        page = try Self.page(try Self.choose("Chief", on: page))
        page = try Self.page(try Self.choose("Leo", on: page))
        let next = try #require(try Self.items(page).first { $0.id == PaletteArgumentFlow.continueRowID }).primary.effect
        guard case .perform(let run) = next.resolved() else {
            Issue.record("Continue did not run the action")
            return
        }
        run()
        #expect(ran?["members"]?.stringValue == "chief_1,user_leo")
    }

    @Test func typedTextIsOfferedAsAMember() throws {
        let page = try Self.page(try Self.flow(Self.registry()).effect(collected: ActionInvocation()))
        let typed = try #require(page.queryItems?("aziz@manaflow.com"))
        let row = try #require(typed.first)
        guard case .replace(let next) = row.primary.effect.resolved() else {
            Issue.record("a typed address is not offered")
            return
        }
        #expect(next.tokens.map(\.title) == ["aziz@manaflow.com"])
        #expect(page.queryItems?("  ").isEmpty ?? true)
    }
}
