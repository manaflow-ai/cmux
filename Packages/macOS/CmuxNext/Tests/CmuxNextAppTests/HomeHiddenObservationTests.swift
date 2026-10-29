import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextWakeups
import Testing

/// A Home that is not on screen reads none of what it shows (plans/cmux-next/
/// chrome-parity/p06-scheduler.md rule 4): its observations are `VisibleObservation`s on the view's
/// node, under its window's node, and AppKit's hide and unhide reach the node. Before, each was an
/// `ObservationStream` loop that read on every change whether the Home showed or not.
@MainActor @Suite(.serialized) struct HomeHiddenObservationTests {
    static let owner = "HomeHost.availability"

    @Test func aHiddenHomeEvaluatesNothingAndShowingItReadsOnce() throws {
        let (services, view, window) = Self.home()
        defer { window.orderOut(nil) }
        #expect(view.visibility.node.isVisible, "a Home in a shown window is visible")
        view.isHidden = true
        #expect(!view.visibility.node.isVisible, "hiding the view did not reach its node")
        let hidden = try Self.counts(services)
        for index in 0..<100 { services.home.migrationNotice = "notice \(index)" }
        let afterChanges = try Self.counts(services)
        #expect(afterChanges.evaluations == hidden.evaluations, "a hidden Home evaluated its availability")
        #expect(afterChanges.applies == hidden.applies, "a hidden Home applied its availability")
        view.isHidden = false
        let shown = try Self.counts(services)
        #expect(shown.showRereads == hidden.showRereads + 1, "showing the Home did not read its availability once")
    }

    @Test func aHomeOutsideAnyWindowIsHidden() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: "conv_no_window")
        #expect(!view.visibility.isShown, "a Home in no window counts as shown")
        #expect(!view.showsChiefOnScreen)
    }

    /// The view's observations rest in an occluded window, but Stop still acts on the Chief as the Home
    /// store has it: the window shows the Chief, another app covers it, the Chief starts a turn, and
    /// `home.stopChief` (the CLI, an agent) must stop that Chief. With the view's last apply it read
    /// "not working" and refused with "no working Chief" while the turn ran.
    @Test func anOccludedHomeStopsTheChiefThatStartedWorkingWhileCovered() async throws {
        let services = try await HomeChiefHostedSettingsTests.servicesWithCloudChiefs()
        let conversation = "conv_named", chief = HomeChiefHostedSettingsTests.namedChief
        let view = HomeHostView(services: services, conversation: conversation)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let source = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView?.addSubview(view)
        let applied = await HomeDaemonNoticeTests.wait { view.isChief }
        #expect(applied, "the shown Home never applied its Chief line")

        source.node.set(.occluded)
        #expect(!view.visibility.node.isVisible, "an occluded window left the Home visible")
        #expect(view.showsChiefOnScreen, "an occluded window's Home is no longer the front Home")
        services.home.homeSource.publish(.typing(ConversationID(conversation), ParticipantID(chief), on: true))
        let typing = await HomeDaemonNoticeTests.wait {
            services.home.homeStore.rows.first { $0.summary.id.rawValue == conversation }?.isTyping == true
        }
        try #require(typing, "the store never saw the Chief type")

        #expect(view.chiefIsWorking, "Stop read the view's last apply, not the store")
        let plan = HomeChiefActions.plan(services.home, front: view)
        #expect(plan.front == .chief(isWorking: true))
        #expect(plan.stop == .front, "home.stopChief refused while the covered Home's Chief worked")
        #expect(view.chiefControl.chief == chief, "Stop names a Chief other than the conversation's")
    }

    // MARK: Fixtures

    static func home() -> (AppServices, HomeHostView, NSWindow) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: "conv_hidden_home")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView?.addSubview(view)
        return (services, view, window)
    }

    static func counts(_ services: AppServices) throws -> ObservationLedger.Entry {
        try #require(services.mainWork.observations.snapshot(matching: owner).first { $0.owner == owner })
    }
}
