import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Testing

/// The group info sheet is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): no SwiftUI bridge; its
/// controls run the model's actions (Remove, Hide Alerts, Add People, Done) and the sheet redraws
/// for them at once.
@MainActor @Suite(.serialized)
struct HomeGroupInfoSheetTests {
    private static let me = ParticipantID("me")
    private static let ada = ParticipantID("ada")
    private static let bob = ParticipantID("bob")

    private static func subviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        subviews(of: root).first { $0.accessibilityIdentifier() == id && !$0.isHiddenOrHasHiddenAncestor }
    }

    @Test func theSheetIsAppKitAndItsControlsRunTheModel() async throws {
        _ = NSApplication.shared
        var muted: [Bool] = []
        let (removed, removedSink) = AsyncStream.makeStream(of: ParticipantID.self)
        let actions = HomeGroupInfoActions(
            rename: { _ in .done }, add: { _, _ in .done },
            remove: { id in removedSink.yield(id); return .done },
            setMuted: { on in muted.append(on); return .done },
            leave: {}, inviteByEmail: {}, setChiefReplies: { _ in .done })
        let info = HomeGroupInfo(conversation: ConversationID("conv_g"), isGroup: true, title: "Launch", displayTitle: "Launch",
                                 members: [HomeGroupMember(id: Self.me, name: "Me", initials: "ME", isMe: true, isAgent: false, isInvited: false),
                                           HomeGroupMember(id: Self.ada, name: "Ada", initials: "AD", isMe: false, isAgent: false, isInvited: false)],
                                 canMute: true, muted: false)
        let model = HomeGroupInfoModel(info: info, addable: [HomeContact(id: Self.bob, name: "Bob", source: .team)], actions: actions)
        let sheet = HomeGroupInfoSheet(model: model, colors: HomeGroupInfoColors())
        var closed = 0
        sheet.onClose = { closed += 1 }
        let root = sheet.view
        root.layoutSubtreeIfNeeded()
        #expect(Self.find("cmux.home.groupInfo", in: root) is HomeGroupInfoView)
        #expect(!hostsSwiftUI(root))
        #expect(Self.find("cmux.home.groupInfo.remove.me", in: root) == nil, "no Remove on my own row")

        let remove = try #require(Self.find("cmux.home.groupInfo.remove.ada", in: root) as? NSButton)
        remove.performClick(nil)
        var iterator = removed.makeAsyncIterator()
        #expect(await iterator.next() == Self.ada)

        let alerts = try #require(Self.find("cmux.home.groupInfo.hideAlerts", in: root) as? NSControl)
        alerts.performClick(nil)
        #expect(muted == [true])

        #expect(Self.find("cmux.home.groupInfo.search", in: root) == nil)
        let addPeople = try #require(Self.find("cmux.home.groupInfo.addPeople", in: root) as? NSButton)
        addPeople.performClick(nil)
        #expect(model.isAdding)
        #expect(Self.find("cmux.home.groupInfo.search", in: root) != nil)
        let bob = try #require(Self.find("cmux.home.groupInfo.add.bob", in: root) as? NSButton)
        bob.performClick(nil)
        #expect(model.isChosen(Self.bob))
        #expect((Self.find("cmux.home.groupInfo.addChosen", in: root) as? NSButton)?.isEnabled == true)

        let done = try #require(Self.find("cmux.home.groupInfo.done", in: root) as? NSButton)
        done.performClick(nil)
        #expect(closed == 1)
    }
}

/// Whether `root`'s own view tree (not the inside of an AppKit control, whose private views on
/// macOS 26 include hosting views of AppKit's own) holds a SwiftUI hosting bridge.
@MainActor
private func hostsSwiftUI(_ root: NSView) -> Bool {
    if String(describing: type(of: root)).contains("Hosting") { return true }
    if root is NSControl { return false }
    return root.subviews.contains { hostsSwiftUI($0) }
}
