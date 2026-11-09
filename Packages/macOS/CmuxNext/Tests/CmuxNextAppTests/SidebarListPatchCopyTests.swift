import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". With a list view attached, one row's patch
/// copied a whole node list: `patchRowsNow` cached the model's section (and the row's group) again, so the cache shared
/// the model's storage and the model's next in-place write (`SidebarRowIndex.set`) copied every node of that section.
/// #39291's cost tests attached no view. This one attaches a real `SidebarListView` and counts the elements copied per
/// patch, in the model's rows and in the list's caches, at 250 and at 3,000 workspaces.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarListPatchCopyTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// `count` workspaces in groups of 25, every fifth group's rows loose (as `SidebarRowsPatchCostTests`).
    static func sections(_ count: Int) -> [SidebarSection] {
        let rows = (0..<count).map { SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "w\($0)", branch: "b0") }
        var nodes: [SidebarNode] = []
        for (g, start) in stride(from: 0, to: count, by: 25).enumerated() {
            let members = Array(rows[start..<min(count, start + 25)])
            if g % 5 == 4 { nodes += members.map { .workspace($0) }; continue }
            nodes.append(.group(SidebarGroup(id: GroupID("g\(g)"), name: "g\(g)", color: .blue, workspaces: members)))
        }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func list(_ count: Int) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(count), activeWorkspaceID: WorkspaceID("w0"))
        let list = SidebarListView(model: model)
        list.pointerIsOverList = { _ in false }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// Each node list and group member list a patch can write, by where it is held, with its storage and length.
    static func buffers(_ list: SidebarListView, group: GroupID) -> [String: (address: UnsafeRawPointer?, count: Int)] {
        func of<T>(_ array: [T]) -> (UnsafeRawPointer?, Int) { (array.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }, array.count) }
        var out: [String: (UnsafeRawPointer?, Int)] = [:]
        let modelSection = list.model.sections[0]
        out["model nodes"] = of(modelSection.nodes)
        if let node = modelSection.nodes.first(where: { $0.id == .group(group) }), case let .group(g) = node {
            out["model group"] = of(g.workspaces)
        }
        if let shown = list.sections[modelSection.id] {
            out["list nodes"] = of(shown.nodes)
            if let node = shown.nodes.first(where: { $0.id == .group(group) }), case let .group(g) = node {
                out["list section group"] = of(g.workspaces)
            }
        }
        if let g = list.groups[group] { out["list group"] = of(g.workspaces) }
        return out
    }

    /// Elements copied per row patch over `count` workspaces (a group member's and a loose row's patches in turn),
    /// after one warm-up patch of each, which may copy once what the last reload shared.
    static func copiedPerPatch(_ count: Int, patches: Int = 20) throws -> (perPatch: Double, by: [String: Int]) {
        let (list, window) = list(count)
        defer { window.close() }
        let model = list.model
        let member = WorkspaceID("w\(count / 2)"), loose = WorkspaceID("w110")
        let group = try #require(model.sections[0].nodes.compactMap { node -> GroupID? in
            guard case let .group(g) = node, g.workspaces.contains(where: { $0.id == member }) else { return nil }
            return g.id
        }.first)
        try #require(model.sections[0].nodes.contains { $0.id == .workspace(loose) }, "w110 is a loose row")
        func patch(_ i: Int) {
            let id = i.isMultiple(of: 2) ? member : loose
            #expect(model.patchWorkspaces([SidebarWorkspace(id: id, title: "\(id.rawValue) \(i)", branch: "b0")]))
        }
        patch(0)
        patch(1)
        let reloads = list.reloads
        var copied: [String: Int] = [:]
        for i in 2..<(2 + patches) {
            let before = buffers(list, group: group)
            patch(i)
            let after = buffers(list, group: group)
            for (name, old) in before where after[name]?.address != old.address { copied[name, default: 0] += old.count }
        }
        try #require(list.reloads == reloads, "a title patch reloaded the list: the count is not a patch's")
        #expect(list.workspaces[member]?.title == "\(member.rawValue) \(patches)")
        #expect(list.groups[group]?.workspaces.first { $0.id == member }?.title == "\(member.rawValue) \(patches)",
                "the list's group cache (its header and hover card) has the patched member")
        let shownSection = try #require(list.sections[model.sections[0].id])
        #expect(shownSection.workspaces.first { $0.id == loose }?.title == "\(loose.rawValue) \(patches + 1)",
                "the list's section cache has the patched loose row")
        return (Double(copied.values.reduce(0, +)) / Double(patches), copied)
    }

    @Test func aRowPatchWithTheListAttachedCopiesNoNodeListAt250OrAt3000Workspaces() throws {
        let small = try Self.copiedPerPatch(250)
        let large = try Self.copiedPerPatch(3000)
        print("sidebar-list-patch-copies elements/patch N=250 \(small.perPatch) N=3000 \(large.perPatch) by N=250 \(small.by) N=3000 \(large.by)")
        // No node list is copied, in the model or the list's caches.
        for name in ["model nodes", "list nodes"] {
            #expect(small.by[name] == nil, "at 250 workspaces a patch copied the \(name): \(small.by)")
            #expect(large.by[name] == nil, "at 3,000 workspaces a patch copied the \(name): \(large.by)")
        }
        // The list's group cache may copy its own 25 members once a member patch, since the header it configures keeps
        // the group it drew (and rolls up those members anyway): the group's size, never the session's.
        #expect(large.perPatch == small.perPatch, "a patch copied \(small.perPatch) elements at 250, \(large.perPatch) at 3,000")
        #expect(large.perPatch <= 25, "a patch copied more than one group's members: \(large.by)")
    }
}
