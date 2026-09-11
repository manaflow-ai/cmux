import Foundation
import Testing
@testable import CmuxFoundation

@MainActor
@Suite("Cloud tree organization")
struct CloudTreeOrganizationStoreTests {
    private struct Node: CloudTreeOrganizationNode {
        let id: String
        var children: [Node] = []
        var canOrganize = true
        var prefersLeadingPlacement = false
        var isPinned = false

        func organized(children: [Node], isPinned: Bool) -> Node {
            var copy = self
            copy.children = children
            copy.isPinned = isPinned
            return copy
        }
    }

    @Test func pendingRowsAndTheirSuccessorsStayProminent() throws {
        let suite = "cloud-tree-pending-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeOrganizationStore<Node>(defaults: defaults)
        let a = Node(id: "a")
        let b = Node(id: "b")
        #expect(store.move("b", by: -1, in: [a, b]))
        store.togglePin("a", in: [a, b])
        let pending = Node(id: "pending", canOrganize: false, prefersLeadingPlacement: true)
        let creating = [pending, a, b]
        #expect(store.arranged(creating).map(\.id) == ["pending", "a", "b"])
        #expect(!store.canMove("a", by: -1, in: creating))
        #expect(!store.move("a", parentID: "", to: 0, in: creating))
        store.togglePin("pending", in: creating)
        #expect(store.arranged(creating).first?.isPinned == false)
        let completed = [Node(id: "created", prefersLeadingPlacement: true), a, b]
        let restored = CloudTreeOrganizationStore<Node>(defaults: defaults)
        #expect(restored.arranged(completed).map(\.id) == ["a", "created", "b"])
        #expect(restored.move("created", by: 1, in: completed))
        #expect(restored.arranged(completed).map(\.id) == ["a", "b", "created"])
    }

    @Test func largeNestedTreeKeepsEveryIdentityAndMissingSlot() throws {
        let suite = "cloud-tree-large-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeOrganizationStore<Node>(defaults: defaults)
        let children = (0..<1000).map { Node(id: "item-\($0)") }
        let tree = [Node(id: "folder", children: children)]
        #expect(store.move("item-999", parentID: "folder", to: 0, in: tree))
        store.togglePin("item-500", in: tree)
        let expected = ["item-500", "item-999"] + (0..<999).filter { $0 != 500 }.map { "item-\($0)" }
        #expect(store.arranged(tree)[0].children.map(\.id) == expected)
        #expect(store.arranged([Node(id: "folder")])[0].children.isEmpty)
        let restored = CloudTreeOrganizationStore<Node>(defaults: defaults)
        let refreshed = [Node(id: "folder", children: children.reversed())]
        #expect(restored.arranged(refreshed)[0].children.map(\.id) == expected)
        #expect(tree[0].children.map(\.id) == children.map(\.id))
    }
}
