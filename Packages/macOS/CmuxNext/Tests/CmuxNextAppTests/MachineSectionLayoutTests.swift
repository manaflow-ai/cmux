import AppKit
@testable import CmuxNextServer
import Foundation
import Testing

/// The right sidebar's Machines section groups (cloud sidebar redesign, ask-2663fecb03): every style keeps
/// every machine, this Mac comes first with no header, and the kinds follow in one fixed order.
@Suite struct MachineSectionLayoutTests {
    private static let local = MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true)
    /// Out of kind order on purpose: grouping must not depend on the registry's order.
    private static let rows = [local] + [
        MachineSectionRow(id: "s1", name: "studio", isConnected: true, isLocal: false, kind: .server),
        MachineSectionRow(id: "h1", name: "linux-box", isConnected: true, isLocal: false, kind: .ssh),
        MachineSectionRow(id: "c1", name: "atlas-web", isConnected: true, isLocal: false, kind: .cloud),
        MachineSectionRow(id: "c2", name: "gpu-box", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true),
    ]

    @Test func groupedStylesPutThisMacFirstThenCloudSSHAndServersUnderHeaders() {
        for style in [MachineSectionStyle.compact, .grouped] {
            let groups = style.groups(Self.rows)
            #expect(groups.map(\.kind) == [nil, .cloud, .ssh, .server])
            #expect(groups.map { $0.rows.map(\.id) } == [["local"], ["c1", "c2"], ["h1"], ["s1"]])
            #expect(groups[0].title == nil)
            #expect(groups[1].title == AddMachineStrings.group(.cloud))
            #expect(Set(groups.map(\.id)).count == groups.count)
        }
    }

    @Test func aKindWithNoMachineHasNoGroup() {
        #expect(MachineSectionStyle.compact.groups([Self.local]).map(\.kind) == [nil])
        #expect(MachineSectionStyle.compact.groups([]).isEmpty)
        #expect(MachineSectionStyle.flat.groups([]).isEmpty)
    }

    @Test func theFlatStyleIsOneUntitledListInTheGivenOrder() {
        let groups = MachineSectionStyle.flat.groups(Self.rows)
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
        #expect(groups[0].rows == Self.rows)
    }

    @Test func everyStyleKeepsEveryMachine() {
        for style in MachineSectionStyle.allCases {
            #expect(style.groups(Self.rows).flatMap(\.rows).count == Self.rows.count)
        }
        #expect(MachineSectionStyle.compact.showsStateLine == false)
        #expect(MachineSectionStyle.grouped.showsStateLine && MachineSectionStyle.flat.showsStateLine)
    }

    @Test func aRowsKindAndStateFollowItsLink() {
        #expect(Self.local.kind == .local)
        #expect(MachineSectionRow(id: "x", name: "x", isConnected: false, isLocal: false).kind == .ssh)
        let connecting = MachineSectionRow(id: "c", name: "c", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(connecting.isConnecting && connecting.stateText == AddMachineStrings.connecting)
        // A connected link is never "connecting", whatever the caller passed.
        let connected = MachineSectionRow(id: "c", name: "c", isConnected: true, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(!connected.isConnecting && connected.stateText == AddMachineStrings.connected)
        #expect(MachineSectionRow(id: "o", name: "o", isConnected: false, isLocal: false).stateText == AddMachineStrings.offline)
        #expect(Set(MachineKind.allCases.map(\.icon)).count == MachineKind.allCases.count)
    }

    /// A paused Cloud machine is not connecting (cloud dogfood: three paused machines spun forever): its
    /// row writes "Paused" with no spinner even while its daemon retries the link. A resume keeps a
    /// spinner, read as "Resuming…"; a failed or deleted machine reads its state; a connected link wins.
    @Test func aCloudMachinesServerStateReplacesTheConnectingSpinner() {
        func row(_ state: MachineServerState?, connected: Bool = false, connecting: Bool = true) -> MachineSectionRow {
            MachineSectionRow(id: "c", name: "c", isConnected: connected, isLocal: false, kind: .cloud, isConnecting: connecting,
                              serverState: state)
        }
        let paused = row(.paused)
        #expect(!paused.isConnecting && paused.stateText == AddMachineStrings.paused)
        let resuming = row(.resuming, connecting: false)
        #expect(resuming.isConnecting && resuming.stateText == AddMachineStrings.resuming)
        #expect(!row(.failed).isConnecting && row(.failed).stateText == AddMachineStrings.failed)
        #expect(!row(.deleted).isConnecting && row(.deleted).stateText == AddMachineStrings.deleted)
        let connected = row(.paused, connected: true)
        #expect(connected.serverState == nil && !connected.isConnecting && connected.stateText == AddMachineStrings.connected)
        // A running machine follows its link.
        #expect(row(nil).isConnecting && row(nil).stateText == AddMachineStrings.connecting)
        #expect(Set(MachineServerState.allCases.map(\.text)).count == MachineServerState.allCases.count)
    }

    /// Inside a group, ready machines come first, then connecting, paused and offline ones (Leo, 2026-10-31:
    /// "ready machines first, then paused, then offline"), each rank in the registry's order; this Mac stays first.
    @Test func readyMachinesComeFirstThenPausedThenOffline() {
        func cloud(_ id: String, connected: Bool = false, connecting: Bool = false, _ state: MachineServerState? = nil) -> MachineSectionRow {
            MachineSectionRow(id: id, name: id, isConnected: connected, isLocal: false, kind: .cloud, isConnecting: connecting, serverState: state)
        }
        let given = [cloud("off1"), cloud("off2"), cloud("paused1", .paused), cloud("ready1", connected: true), cloud("failed1", .failed),
                     cloud("paused2", .paused), cloud("resuming1", .resuming), cloud("ready2", connected: true)]
        let order = ["ready1", "ready2", "resuming1", "paused1", "paused2", "off1", "off2", "failed1"]
        for style in [MachineSectionStyle.compact, .grouped] {
            let groups = style.groups(given + [Self.local])
            #expect(groups.map { $0.rows.map(\.id) } == [["local"], order], "\(style)")
        }
        #expect(MachineSectionStyle.flat.groups(given + [Self.local]).first?.rows.map(\.id) == ["local"] + order)
    }

    @Test func theFixtureHasEveryRemoteKindAndState() {
        let fixture = MachineSectionRow.fixtures
        #expect(Set(fixture.map(\.kind)) == [.cloud, .ssh, .server])
        #expect(fixture.contains { $0.isConnecting })
        #expect(fixture.contains { !$0.isConnected && !$0.isConnecting })
        #expect(fixture.contains { $0.serverState == .paused && !$0.isConnecting })
        #expect(Set(fixture.map(\.id)).count == fixture.count)
        #expect(!fixture.contains { $0.isLocal })
    }
}

/// The Machines section is AppKit (no-swiftui-DESIGN wave 1): its rows react to model changes, its
/// buttons run their actions, and New Workspace shows only under the pointer or while the row's menu is open.
@MainActor @Suite struct MachineSectionViewTests {
    private static let rows = [
        MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true),
        MachineSectionRow(id: "c1", name: "atlas-web", isConnected: true, isLocal: false, kind: .cloud),
        MachineSectionRow(id: "c2", name: "gpu-box", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true),
        MachineSectionRow(id: "h1", name: "build-host", isConnected: false, isLocal: false, kind: .ssh),
    ]

    private static func section(_ opened: @escaping @MainActor (String) -> Void = { _ in },
                                add: @escaping @MainActor () -> Void = {}) -> MachineSectionView {
        let view = MachineSectionView(actions: MachineSectionView.Actions(newWorkspace: opened, addMachine: add, newWorkspaceMenuItem: { _ in
            NSMenuItem(title: "registry row", action: nil, keyEquivalent: "")
        }))
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        return view
    }

    @Test func eachStyleShowsItsHeadersAndStates() {
        let view = Self.section()
        view.update(Self.rows, style: .compact)
        #expect(view.shownLines == ["This Mac", AddMachineStrings.group(.cloud)!, "atlas-web", "gpu-box",
                                    AddMachineStrings.group(.ssh)!, "build-host · \(AddMachineStrings.offline)", AddMachineStrings.addMachine])
        view.update(Self.rows, style: .flat)
        #expect(view.shownLines == ["This Mac · \(AddMachineStrings.connected)", "atlas-web · \(AddMachineStrings.connected)",
                                    "gpu-box · \(AddMachineStrings.connecting)", "build-host · \(AddMachineStrings.offline)",
                                    AddMachineStrings.addMachine])
    }

    /// The compact row of a paused Cloud machine shows "Paused" at its trailing edge and no spinner; a
    /// connecting one shows the spinner and no word.
    @Test func aPausedCloudRowShowsPausedAndNoSpinner() throws {
        let view = Self.section()
        let paused = MachineSectionRow(id: "c3", name: "night-batch", isConnected: false, isLocal: false, kind: .cloud,
                                       isConnecting: true, serverState: .paused)
        view.update(Self.rows + [paused], style: .compact)
        let pausedRow = try #require(view.rowViews["c3"]), connectingRow = try #require(view.rowViews["c2"])
        #expect(!pausedRow.showsSpinner && pausedRow.shownText == "night-batch · \(AddMachineStrings.paused)")
        #expect(connectingRow.showsSpinner && connectingRow.shownText == "gpu-box")
        #expect(!pausedRow.newButton.isEnabled)
    }

    @Test func rowsFollowTheModelAndKeepTheirViews() {
        let view = Self.section()
        view.update(Self.rows, style: .compact)
        let kept = view.rowViews["c1"]
        view.update(Array(Self.rows.prefix(2)), style: .compact)
        #expect(view.rowViews.keys.sorted() == ["c1", "local"])
        #expect(view.rowViews["c1"] === kept)
        #expect(!view.shownLines.contains(AddMachineStrings.group(.ssh)!))
        view.layoutSubtreeIfNeeded()
        let frames = view.subviews.map(\.frame).sorted { $0.minY < $1.minY }
        #expect(view.subviews.count == 4) // This Mac, the Cloud header, atlas-web, Add Machine…
        #expect(frames.allSatisfy { $0.width == 280 })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY })
    }

    /// Joined machines (Labs `labs.machineJoin`): a mesh-only one sits under the Joined header after the
    /// other kinds, a linked one stays in its link's group; both are the joined row with its "…" menu,
    /// and the store's busy, failed and open-menu state reaches them.
    @Test func joinedMachinesSitInTheirGroupsAsJoinedRows() throws {
        let linkedMachine = JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, meshPeerId: "h1", mintedBy: "you@example.com")
        let meshMachine = JoinedMachine(id: "m_2", name: "gpu-west", state: .offline)
        let linked = MachineSectionRow(id: "h1", name: "lane-vm-3", isConnected: true, isLocal: false, kind: .ssh, joined: linkedMachine)
        let mesh = MachineSectionRow.joined(meshMachine, health: nil)
        #expect(mesh.kind == .joined && !mesh.isLinked && linked.isLinked)
        var menus: [String] = []
        let view = MachineSectionView(actions: MachineSectionView.Actions(newWorkspace: { _ in }, addMachine: {}, joinedMenu: { machine, row in
            menus.append("\(machine.id)@\(row.id)")
            return NSMenu()
        }))
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        view.update([Self.rows[0], mesh, linked], style: .compact, joined: .init(busy: ["m_2"], openMenu: "m_1"))
        let lines = view.shownLines
        #expect(lines.first == "This Mac")
        let ssh = try #require(lines.firstIndex(of: AddMachineStrings.group(.ssh)!))
        let joined = try #require(lines.firstIndex(of: AddMachineStrings.group(.joined)!))
        #expect(ssh < joined)
        #expect(lines[ssh + 1].hasPrefix("lane-vm-3 · "))
        #expect(lines[joined + 1].hasPrefix("gpu-west · "))
        #expect(view.rowViews.keys.sorted() == ["local"], "joined machines are joined rows, never plain ones")
        #expect(view.joinedViews.keys.sorted() == [mesh.id, "h1"].sorted())
        let linkedView = try #require(view.joinedViews["h1"]), meshView = try #require(view.joinedViews[mesh.id])
        #expect(linkedView.snapshot?.menuOpen == true && linkedView.snapshot?.isLinked == true)
        #expect(meshView.snapshot?.busy == true && meshView.snapshot?.isLinked == false)
        #expect(linkedView.add.isEnabled && !meshView.add.isEnabled)
        // The trailing workspace action is quiet at rest, then follows the row hover/menu state.
        #expect(linkedView.add.alphaValue == 1) // the open menu keeps row actions revealed
        view.update([Self.rows[0], mesh, linked], style: .compact, joined: .init())
        #expect(linkedView.add.alphaValue == 0)
        linkedView.setHovered(true)
        #expect(linkedView.add.alphaValue == 1)
        linkedView.setHovered(false)
        #expect(linkedView.add.alphaValue == 0)
        _ = linkedView.more.pressMenu?()
        #expect(menus == ["m_1@h1"])
        // The store's state alone changing reaches the rows.
        view.update([Self.rows[0], mesh, linked], style: .compact, joined: .init())
        #expect(view.joinedViews[mesh.id]?.snapshot?.busy == false)
        #expect(view.joinedViews[mesh.id] === meshView)
    }

    @Test func newWorkspaceShowsUnderThePointerAndRunsOnlyWhenConnected() throws {
        var opened: [String] = []
        let view = Self.section { opened.append($0) }
        view.update(Self.rows, style: .compact)
        let row = try #require(view.rowViews["c1"])
        #expect(!row.revealsNewWorkspace)
        row.setPointerInside(true)
        #expect(row.revealsNewWorkspace)
        row.newButton.performClick(nil)
        row.setPointerInside(false)
        #expect(!row.revealsNewWorkspace)
        let down = try #require(view.rowViews["h1"])
        #expect(!down.newButton.isEnabled)
        #expect(down.newButton.accessibilityPerformPress() == false)
        #expect(down.contextMenu()?.items.first?.isEnabled == false)
        #expect(opened == ["c1"])
        #expect(row.contextMenu()?.items.map(\.title) == [AddMachineStrings.newWorkspace])
        // With no registry row the machine has no right-click menu (no inline fallback).
        #expect(MachineSectionRowView(newWorkspace: { _ in }).contextMenu() == nil)
    }

    @Test func addMachineRunsItsAction() {
        var added = 0
        let view = Self.section(add: { added += 1 })
        view.update(Self.rows, style: .grouped)
        #expect(view.addRow.accessibilityPerformPress())
        #expect(added == 1)
    }

    /// Keyboard (Full Keyboard Access), as the SwiftUI buttons had: New Workspace shows while it has focus,
    /// and Space or Return runs Add Machine… when it has focus.
    @Test func keyboardFocusShowsNewWorkspaceAndSpaceRunsAddMachine() throws {
        var added = 0
        let view = Self.section(add: { added += 1 })
        view.update(Self.rows, style: .compact)
        let row = try #require(view.rowViews["c1"])
        #expect(!row.revealsNewWorkspace)
        #expect(row.newButton.becomeFirstResponder())
        #expect(row.revealsNewWorkspace)
        #expect(row.newButton.resignFirstResponder())
        #expect(!row.revealsNewWorkspace)
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }
        #expect(MachineSectionAddRow.activates(try key(" ")))
        #expect(MachineSectionAddRow.activates(try key("\r")))
        #expect(!MachineSectionAddRow.activates(try key("a")))
        #expect(!MachineSectionAddRow.activates(try key(" ", .command)))
        #expect(!MachineSectionAddRow.activates(try key(" ", .shift)))
        view.addRow.keyDown(with: try key(" "))
        #expect(added == 1)
        view.addRow.keyboardAccess = { false }
        #expect(!view.addRow.acceptsFirstResponder && !view.addRow.canBecomeKeyView)
        view.addRow.keyboardAccess = { true }
        #expect(view.addRow.acceptsFirstResponder && view.addRow.canBecomeKeyView)
        #expect(view.addRow.becomeFirstResponder() && view.addRow.showsFocus)
        #expect(view.addRow.resignFirstResponder() && !view.addRow.showsFocus)
    }

    /// A name or header that fits is drawn whole (a label's frame is its text plus padding), and every
    /// name, and Add Machine…, starts on one text column after the icon column.
    @Test func namesThatFitAreWholeAndShareOneColumn() {
        for style in MachineSectionStyle.allCases {
            let view = Self.section()
            view.update(Self.rows, style: style)
            view.layoutSubtreeIfNeeded()
            var starts: Set<CGFloat> = []
            for row in view.rowViews.values {
                row.layoutSubtreeIfNeeded()
                #expect(row.nameLabel.frame.width >= row.nameLabel.naturalSize.width - 0.5, "\(style) \(row.row.name)")
                if !row.stateLabel.isHidden {
                    #expect(row.stateLabel.frame.width >= row.stateLabel.naturalSize.width - 0.5, "\(style) \(row.row.name)")
                }
                starts.insert(row.nameLabel.frame.minX)
            }
            view.addRow.layoutSubtreeIfNeeded()
            starts.insert(view.addRow.label.frame.minX)
            #expect(starts.count == 1, "\(style): \(starts)")
        }
    }

    /// A name too long for its column is shown whole (Leo's DEV build cut a long name mid-word,
    /// "abc-defghi...-xyz"): it wraps, the row grows to hold it, and the rows below move down.
    @Test func aLongNameWrapsWholeAndItsRowGrows() throws {
        let long = MachineSectionRow(id: "c9", name: "an-uncommonly-long-machine-name-from-a-person", isConnected: false, isLocal: false,
                                     kind: .cloud, serverState: .paused)
        for style in MachineSectionStyle.allCases {
            let view = Self.section()
            view.frame.size.width = 220
            view.update(Self.rows + [long], style: style)
            view.layoutSubtreeIfNeeded()
            let row = try #require(view.rowViews["c9"]), short = try #require(view.rowViews["c1"])
            row.layoutSubtreeIfNeeded()
            short.layoutSubtreeIfNeeded()
            let label = row.nameLabel
            #expect(label.maximumNumberOfLines == 0 && label.wraps, "\(style)")
            #expect(label.frame.height > short.nameLabel.frame.height + 1, "\(style): the name takes more than one line")
            #expect(label.frame.height <= label.size(forWidth: label.frame.width).height + 0.5, "\(style): every line shows")
            #expect(row.frame.height > short.frame.height, "\(style)")
            #expect(label.frame.maxX <= row.newButton.frame.minX, "\(style): the name stays clear of New Workspace")
            if !row.stateLabel.isHidden, !style.showsStateLine {
                #expect(label.frame.maxX <= row.stateLabel.frame.minX, "\(style): and of its state")
            }
            #expect(row.shownText.hasPrefix(long.name), "\(style)")
        }
    }

    /// The click reaches Add Machine… as AppKit dispatches it: a view's hitTest takes a point in its
    /// superview's coordinates, and each view hands its subviews the point in its own. The section sits
    /// at a nonzero origin in a flipped host, so a double or missing conversion would miss. Only the
    /// icon and the text take the click, not the empty width after them.
    @Test func addMachineTakesTheClickOnlyOverItsIconAndText() {
        let view = Self.section()
        view.update(Self.rows, style: .compact)
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        view.frame.origin = NSPoint(x: 0, y: 37)
        host.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let add = view.addRow
        add.layoutSubtreeIfNeeded()
        #expect(add.frame.minY > 0)
        let text = NSPoint(x: add.label.frame.midX, y: add.label.frame.midY)
        #expect(view.hitTest(host.convert(text, from: add)) === add)
        #expect(add.hitTest(view.convert(text, from: add)) === add)
        let past = NSPoint(x: add.bounds.maxX - 2, y: add.bounds.midY)
        #expect(view.hitTest(host.convert(past, from: add)) !== add)
        #expect(add.hitTest(view.convert(past, from: add)) == nil)
    }

    @Test func theSectionAndItsHostImportNoSwiftUI() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        for path in ["CmuxNextServer/AddMachine/MachineSectionView.swift", "CmuxNextServer/AddMachine/MachineSection.swift",
                     "CmuxNextApp/RightSidebar/MachineSectionHostView.swift"] {
            let source = try String(contentsOf: sources.appending(path: path), encoding: .utf8)
            #expect(!source.contains("import SwiftUI"), "\(path)")
            #expect(!source.contains("NSHostingView"), "\(path)")
        }
    }
}

/// A flipped container, so a point given to it is in the same top-down coordinates as the section's.
private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}
