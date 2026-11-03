import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-01: cloud/remote distinction "just on the hover preview". Leo 2026-11-02, on a Cloud card that said
/// Cloud four times: "isn't this extremely stupid looking?" / "the tiny cloud icon the repeated cloud cloud cloud".
/// The card names the machine once, beside the title, its dot beside it.
@MainActor @Suite(.serialized) struct WorkspaceHoverHostIdentityTests {
    /// How many times `word` reads on the card, across every line.
    private func count(_ word: String, in lines: [String]) -> Int {
        lines.map { $0.components(separatedBy: word).count - 1 }.reduce(0, +)
    }

    @Test(arguments: [SidebarMachine.Kind.cloud, .ssh, .server, .local])
    func thePreviewShowsHostIdentityWithoutOpeningDetails(_ kind: SidebarMachine.Kind) throws {
        var machine = SidebarMachine(id: MachineID("host"), name: "Build host", kind: kind)
        // A custom machine mark must not obscure the requested cloud/globe distinction.
        machine.icon = .symbol("star")
        let workspace = SidebarWorkspace(id: WorkspaceID("workspace"), machineID: machine.id, title: "Ship the fix")
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date())
        let view = WorkspaceHoverCardView()
        view.configure(content)
        #expect(!view.isDetailsExpanded)
        if kind == .local {
            #expect(content.host == nil)
            #expect(!view.lines.contains(machine.name))
            #expect(!view.lines.contains(Strings.hoverCloud))
        } else {
            let host = try #require(content.host)
            let label = kind == .cloud ? Strings.hoverCloud : machine.name
            #expect(host.text == label)
            #expect(host.mark == (kind == .cloud ? nil : "globe"))
            if kind == .cloud { #expect(host.icon == .cloud) }
            #expect(view.lines.first == "Ship the fix \(label)", "the machine reads beside the title: \(view.lines)")
            #expect(count(label, in: view.lines) == 1)
            view.expandDetails()
            #expect(count(label, in: view.lines) == 1, "expanded details must not duplicate the host: \(view.lines)")
            view.configure(.make(workspace, machine: nil, now: Date()))
            #expect(!view.lines.contains(label), "reusing a card for local content must clear the host")
        }
    }

    /// The card in Leo's screenshot: a Cloud workspace with one terminal. "Cloud" reads once, in the header; the
    /// terminal's row no longer repeats it.
    @Test func aCloudCardNamesItsMachineExactlyOnce() {
        let machine = SidebarMachine(id: MachineID("cloud"), name: "cmux-vm-1", kind: .cloud)
        var workspace = SidebarWorkspace(id: WorkspaceID("workspace"), machineID: machine.id, title: "workspace-2")
        workspace.tabs = [SidebarTab(id: TabID("t"), title: "Terminal", kind: .terminal)]
        let view = WorkspaceHoverCardView()
        view.configure(.make(workspace, machine: machine, now: Date()))
        view.configureTabs(title: workspace.title, tabs: workspace.tabs, machine: machine)
        #expect(count(Strings.hoverCloud, in: view.lines) == 1, "\(view.lines)")
        #expect(view.lines.first == "workspace-2 \(Strings.hoverCloud)", "\(view.lines)")
        view.expandDetails()
        #expect(count(Strings.hoverCloud, in: view.lines) == 1, "expanded: \(view.lines)")
    }

    @Test func theMinimalCardKeepsTheCloudIdentity() {
        let machine = SidebarMachine(id: MachineID("cloud"), name: "Private machine name", kind: .cloud)
        let workspace = SidebarWorkspace(id: WorkspaceID("workspace"), machineID: machine.id, title: "Ship the fix")
        var options = WorkspaceHoverCardOptions()
        options.layout = .minimal
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: Date(), options: options, timeline: [])
        #expect(content.host?.text == Strings.hoverCloud)
        #expect(!content.facts.contains { $0.kind == "machine" })
    }
}
