import AppKit
@testable import CmuxNextPages
import Foundation
import Testing

/// The link and path menus' LaunchServices answers belong to the router the menus are built with
/// (``LinkRouter/menuApps``), not to a process-wide cache: every menu of one router reads the kept
/// answer, and another router (a test's) asks for its own.
@MainActor struct LinkMenuAppCacheOwnerTests {
    // Sendable constants the @Sendable LaunchServices closures read off the main actor.
    private nonisolated static let first = URL(fileURLWithPath: "/Applications/First.app")
    private nonisolated static let second = URL(fileURLWithPath: "/Applications/Second.app")

    @Test func aRouterKeepsItsAnswerForTheNextMenu() {
        let router = LinkRouter()
        let key = "link:x-cmux-owner-test"
        #expect(router.menuApps.apps(for: key) { [Self.first] } == [Self.first])
        // The second menu shows the kept answer at once; the refresh runs in the background.
        #expect(router.menuApps.apps(for: key) { [Self.second] } == [Self.first], "the next menu asked LaunchServices again")
    }

    @Test func anotherRouterDoesNotReadTheFirstRoutersAnswer() {
        let key = "type:x-cmux-owner-test"
        let one = LinkRouter(), other = LinkRouter()
        #expect(one.menuApps.apps(for: key) { [Self.first] } == [Self.first])
        #expect(other.menuApps.apps(for: key) { [Self.second] } == [Self.second], "two routers shared one cache")
    }

    @Test func aRoutersAppIconIsReadOnce() {
        let router = LinkRouter()
        let icon = router.menuApps.icon(for: Self.first)
        #expect(icon.size == NSSize(width: 16, height: 16))
        #expect(router.menuApps.icon(for: Self.first) === icon, "the icon was read again")
    }
}
