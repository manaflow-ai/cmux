import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-01: cloud/remote distinction "just on the hover preview".
@MainActor @Suite(.serialized) struct WorkspaceHoverHostIdentityTests {
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
            #expect(view.lines.filter { $0 == label }.count == 1)
            view.expandDetails()
            #expect(view.lines.filter { $0 == label }.count == 1, "expanded details must not duplicate the host")
            view.configure(.make(workspace, machine: nil, now: Date()))
            #expect(!view.lines.contains(label), "reusing a card for local content must clear the host")
        }
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
