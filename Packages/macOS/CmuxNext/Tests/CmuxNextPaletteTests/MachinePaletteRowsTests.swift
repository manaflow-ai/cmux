import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Machine actions in the palette: typing a machine's name lists "Connect to Machine: devbox" and the
/// like, and a row runs its action on that machine in one step, as the action's picker would.
@MainActor @Suite struct MachinePaletteRowsTests {
    private let devbox = PaletteTargetOption(id: "me@devbox:2222", title: "devbox", symbol: "server.rack")

    private func rows(_ machines: [PaletteTargetOption], pass: MachinePaletteRows.Pass = .argument("destination"),
                      ran: @escaping @MainActor (ActionInvocation) -> Void = { _ in }) -> [PaletteItem] {
        MachinePaletteRows.rows(action: "remote.connect", title: "Connect to Machine…", keywords: ["ssh", "remote"],
                                symbol: "cable.connector", pass: pass, machines: machines, perform: ran)
    }

    private func run(_ item: PaletteItem) {
        guard case let .perform(run) = item.primary.effect else {
            Issue.record("a machine row runs its action, it does not open a page")
            return
        }
        run()
    }

    @Test func eachMachineRowIsTitledByTheActionAndPassesTheMachineAsItsArgument() throws {
        var ran: [ActionInvocation] = []
        let items = rows([devbox, PaletteTargetOption(id: "studio", title: "studio")]) { ran.append($0) }
        #expect(items.map(\.title) == ["Connect to Machine: devbox", "Connect to Machine: studio"])
        let row = try #require(items.first)
        #expect(row.keywords.contains("devbox"))
        #expect(row.keywords.contains("ssh"))
        #expect(row.keywords.contains("machine"))
        #expect(row.symbol == "cable.connector")
        #expect(row.frecencyKey == "machines.actions:remote.connect:me@devbox:2222")
        #expect(row.id == row.frecencyKey)
        #expect(row.actionID == "remote.connect")
        #expect(row.primary.title == "Connect to Machine")
        run(row)
        #expect(ran.count == 1)
        #expect(ran.first?["destination"]?.stringValue == "me@devbox:2222")
        #expect(ran.first?.target == nil)
        #expect(ran.first?.origin == .user)
    }

    @Test func aTargetActionPassesTheMachineAsItsTarget() throws {
        var ran: [ActionInvocation] = []
        let items = MachinePaletteRows.rows(action: "cloudSSH", title: "Open Cloud SSH Terminal", keywords: ["cloud"], symbol: "terminal",
                                            pass: .target, machines: [PaletteTargetOption(id: "m_7", title: "lane-3")]) { ran.append($0) }
        let row = try #require(items.first)
        #expect(row.title == "Open Cloud SSH Terminal: lane-3")
        #expect(row.frecencyKey == "machines.actions:cloudSSH:m_7")
        run(row)
        #expect(ran.first?.target == ActionTargetRef(kind: .machine, id: "m_7"))
        #expect(ran.first?.arguments.isEmpty == true)
    }

    @Test func unnamedDisabledRepairAndRepeatedMachinesGetNoRow() {
        let machines = [
            devbox,
            PaletteTargetOption(id: "blank", title: "  "),
            PaletteTargetOption(id: "", title: "no id"),
            PaletteTargetOption(id: "off", title: "off", isEnabled: false),
            PaletteTargetOption(id: "add-machine", title: "Add Machine…", recovery: PaletteTargetRecovery(action: "machine.add", title: "Add Machine…")),
            PaletteTargetOption(id: devbox.id, title: "devbox again"),
        ]
        #expect(rows(machines).map(\.title) == ["Connect to Machine: devbox"])
    }

    @Test func manyMachinesStayBounded() {
        let machines = (0..<500).map { PaletteTargetOption(id: "m\($0)", title: "host-\($0)") }
        let items = rows(machines)
        #expect(items.count == MachinePaletteRows.perActionLimit)
        #expect(items.last?.title == "Connect to Machine: host-\(MachinePaletteRows.perActionLimit - 1)")
    }

    @Test func noTitleListsNoRows() {
        #expect(MachinePaletteRows.rows(action: "remote.connect", title: "…", keywords: [], symbol: "x", pass: .target,
                                        machines: [devbox], perform: { _ in }).isEmpty)
        #expect(MachinePaletteRows.actionTitle("New Workspace on Machine…") == "New Workspace on Machine")
        #expect(MachinePaletteRows.actionTitle("Open Cloud SSH Terminal") == "Open Cloud SSH Terminal")
    }

    @Test func theStandardActionsPassWhatTheirPickersPass() {
        let actions = MachinePaletteRows.standard(targets: { nil }, sshDestinations: { [] })
        #expect(actions.map(\.id) == ["remote.connect", "workspace.newOnMachine", "cloudSSH"])
        #expect(actions.map(\.pass) == [.argument("destination"), .argument("machine"), .target])
        #expect(actions.allSatisfy { $0.machines().isEmpty })
    }

    @Test func theProviderListsNothingForTheEmptyQuery() {
        let provider = MachinePaletteRows(actions: []).provider(registry: ActionRegistry(catalog: []))
        #expect(provider.showsItemsForEmptyQuery == false)
        #expect(provider.id == MachinePaletteRows.providerID)
    }
}
