#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// User report 2026-10-21 (screen recording): tapping Chief on Home pushed
/// the conversation, then pushed it a second time. With the Cloud Chief
/// ready and a Mac linked, Home pins two Chiefs side by side in one `List`
/// row, and both pins were `NavigationLink`s: `List` treats the row as one
/// cell and a tap there activates every link in it, so the stack pushed the
/// Cloud Chief and the Mac Chief on top of it. Each pin now pushes only its
/// own route.
@MainActor
@Suite struct ChiefPinPushTests {
    /// Home as the shell builds it: ConversationsHome in a NavigationStack
    /// over a NavigationPath; `open` appends the route, as HomeScreen does.
    struct Home: View {
        let sources: ChiefSources
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [])
        @Binding var path: NavigationPath

        var body: some View {
            NavigationStack(path: $path) {
                ConversationsHome(store: store, sources: sources, open: { route in
                    if let chief = route.chiefRoute { path.append(chief) }
                }) {
                    ToolbarItem(placement: .topBarLeading) { EmptyView() }
                }
            }
        }
    }

    final class PathBox {
        var path = NavigationPath()
    }

    @Test func tappingOneOfTwoChiefPinsPushesOnlyThatChief() throws {
        let mac = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let cloud = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let sources = ChiefSources(mac: mac, cloud: cloud, selection: UserDefaults(suiteName: "chief-pins-\(UUID())")!)
        // Cloud Chief ready and a Mac linked: Home pins both.
        sources.cloudState = .ready(CloudChief(id: "c1", displayName: "Chief", isDefault: true, mainConversation: "conv", rev: 1))
        mac.macName = "cmux mini"
        #expect(sources.secondary === mac)

        let box = PathBox()
        let binding = Binding(get: { box.path }, set: { box.path = $0 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Home(sources: sources, path: binding))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // A tap on the pins' row: List selects the row, which is what a
        // finger on either pin does (the row is one List cell).
        let list = try #require(drain(until: { () -> UICollectionView? in
            guard let list = window.firstSubview(of: UICollectionView.self), !list.indexPathsForVisibleItems.isEmpty else { return nil }
            return list
        }))
        let pinsRow = IndexPath(item: 0, section: 0)
        if list.delegate?.collectionView?(list, shouldSelectItemAt: pinsRow) ?? true {
            list.selectItem(at: pinsRow, animated: false, scrollPosition: [])
            list.delegate?.collectionView?(list, didSelectItemAt: pinsRow)
        }
        // Let the push and anything it sets off land.
        for _ in 0 ..< 60 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        #expect(box.path.count <= 1, "one tap pushed \(box.path.count) Chiefs")
        let navigation = window.rootViewController?.firstNavigation()
        #expect((navigation?.viewControllers.count ?? 1) <= 2, "never a Chief pushed over a Chief")
    }

    private func drain<T>(until value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let found = value() { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return value()
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T { return match }
            if let found = view.firstSubview(of: type) { return found }
        }
        return nil
    }
}

private extension UIViewController {
    func firstNavigation() -> UINavigationController? {
        if let navigation = self as? UINavigationController { return navigation }
        for child in children {
            if let found = child.firstNavigation() { return found }
        }
        return nil
    }
}
#endif
