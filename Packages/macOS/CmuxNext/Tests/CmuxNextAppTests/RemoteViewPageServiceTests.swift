import CmuxNextActions
import CmuxNextRemoteView
import Foundation
import Testing
@testable import CmuxNextApp

/// Who may confirm a `remote_view` tab (plans/cmux-next/remote-desktop.md 7):
/// only a person, and only for the exact record they saw.
@MainActor
struct RemoteViewPageServiceTests {
    private let url = URL(string: "cmux://remote-view?host=mock&target=display:1&mode=view")!

    @Test func automationRunsCannotConfirm() {
        for origin in ActionOrigin.allCases where origin != .user {
            let service = RemoteViewPageService()
            service.confirm("tab_1", url: url, scope: ActionRunScope(origin: origin, allowsViewChange: true))
            #expect(service.source(for: "tab_1", url: url, isLocal: true) == .unconfirmed, "\(origin)")
        }
    }

    @Test func aPersonConfirmsTheExactRecord() {
        let service = RemoteViewPageService()
        #expect(service.source(for: "tab_1", url: url, isLocal: true) == .unconfirmed)
        service.confirm("tab_1", url: url, scope: nil)
        #expect(service.source(for: "tab_1", url: url, isLocal: true) == .person)
        let control = URL(string: "cmux://remote-view?host=mock&target=display:1&mode=control")!
        #expect(service.source(for: "tab_1", url: control, isLocal: true) == .unconfirmed)
        #expect(service.source(for: "tab_2", url: url, isLocal: true) == .unconfirmed)
        service.forget("tab_1")
        #expect(service.source(for: "tab_1", url: url, isLocal: true) == .unconfirmed)
    }

    @Test func userOriginRunsConfirm() {
        let service = RemoteViewPageService()
        service.confirm("tab_1", url: url, scope: ActionRunScope(origin: .user, allowsViewChange: true))
        #expect(service.source(for: "tab_1", url: url, isLocal: true) == .person)
    }

    @Test func remoteTreesAreAlwaysRemote() {
        let service = RemoteViewPageService()
        service.confirm("tab_1", url: url, scope: nil)
        #expect(service.source(for: "tab_1", url: url, isLocal: false) == .remoteTree)
    }
}
