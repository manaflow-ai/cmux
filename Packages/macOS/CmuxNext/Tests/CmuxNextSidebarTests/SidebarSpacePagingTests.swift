import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The pager must release its input lock when a profile selection supersedes
/// the profile requested by an in-flight swipe (issue #21086).
@MainActor @Suite(.serialized) struct SidebarSpacePagingTests {
    static let keys = ["a", "b", "c", "d", "e"].map(ProfileKey.init)

    static func sidebar() -> (SidebarView, NSWindow) {
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                                           nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-a"), title: "ws-a"))])])
        model.profiles = keys.map { SidebarProfile(id: $0, name: $0.rawValue) }
        model.activeProfileID = keys[0]
        model.spaceSections = { key in
            [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                            nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-\(key.rawValue)"), title: "ws-\(key.rawValue)"))])]
        }
        let view = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return (view, window)
    }

    /// Release a swipe that targets the next profile, leaving its model
    /// callback outstanding just as a real daemon switch would.
    static func leavePendingSwipe(_ paging: SidebarSpacePaging) {
        paging.scroll(.began, deltaX: -10, time: 1.00)
        paging.scroll(.changed, deltaX: -180, time: 1.03)
        paging.scroll(.ended, deltaX: 0, time: 1.04)
    }

    @Test func theRequestedProfileCompletesTheSwipeWithoutASecondSlide() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let paging = view.spacePaging
        Self.leavePendingSwipe(paging)
        #expect(paging.pendingTarget == Self.keys[1])

        let oldSections = view.model.sections
        view.model.activeProfileID = Self.keys[1]
        view.switchSpace(from: Self.keys[0], to: Self.keys[1], profiles: view.model.profiles, oldSections: oldSections)

        // The real list replaces the swipe's preview directly. A second
        // dot-style slide would retain a snapshot and clip the live list.
        #expect(paging.pendingTarget == nil)
        #expect(paging.neighbor == nil)
        #expect(paging.snapshotView == nil)
        #expect(!view.clipsToBounds)

        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        paging.page(by: 1)
        #expect(intents == [.switchProfile(Self.keys[2])])
    }

    @Test func aDifferentProfileSelectionClearsThePendingSwipeBeforeWheelPaging() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let paging = view.spacePaging
        Self.leavePendingSwipe(paging)
        #expect(paging.pendingTarget == Self.keys[1])

        // The user selects profile C while the swipe's request for B is still
        // waiting for the model callback.
        let oldSections = view.model.sections
        view.model.activeProfileID = Self.keys[2]
        view.switchSpace(from: Self.keys[0], to: Self.keys[2], profiles: view.model.profiles, oldSections: oldSections)
        #expect(paging.pendingTarget == nil)

        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        paging.page(by: 1)
        #expect(intents == [.switchProfile(Self.keys[3])])
    }

    @Test func aDifferentProfileSelectionLeavesHorizontalPagingUsable() throws {
        let (view, window) = Self.sidebar()
        defer { window.close() }
        let paging = view.spacePaging
        Self.leavePendingSwipe(paging)
        #expect(paging.pendingTarget == Self.keys[1])

        let oldSections = view.model.sections
        view.model.activeProfileID = Self.keys[2]
        view.switchSpace(from: Self.keys[0], to: Self.keys[2], profiles: view.model.profiles, oldSections: oldSections)
        #expect(paging.pendingTarget == nil)

        // A new gesture is accepted immediately and can establish its own
        // pending target instead of being rejected by the stale B request.
        Self.leavePendingSwipe(paging)
        #expect(paging.pendingTarget == Self.keys[3])
    }
}
