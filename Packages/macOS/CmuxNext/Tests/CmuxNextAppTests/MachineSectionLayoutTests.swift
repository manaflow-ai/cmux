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

    @Test func theFixtureHasEveryRemoteKindAndState() {
        let fixture = MachineSectionModel.fixtureRows
        #expect(Set(fixture.map(\.kind)) == [.cloud, .ssh, .server])
        #expect(fixture.contains { $0.isConnecting })
        #expect(fixture.contains { !$0.isConnected && !$0.isConnecting })
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
