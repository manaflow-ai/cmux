import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// Catalog request rows (cmux-action-catalog `Action::request`): the app decodes a row's request
/// and an `op:` list from the catalog JSON, resolves each param, reads a list's rows, refuses a
/// relayed run, and binds every request row that no other handler took.
@MainActor
struct CatalogRequestHandlersTests {
    /// The app form of a request row, as `json::app_action` writes it.
    static let row: [String: Any] = [
        "id": "closed.delete", "category": "window", "surfacePlan": ["palette": "offered"],
        "arguments": [[
            "name": "closed", "title": "Closed", "kind": "string", "isRequired": true,
            "suggestions": ["source": "op:closed.list", "list": ["lane": "session", "operation": "closed.list", "value": "id", "title": "name"]],
        ], [
            "name": "members", "title": "Members", "kind": "string",
            "suggestions": ["source": "x", "allowsMultiple": true],
        ]],
        "request": [
            "lane": "session", "operation": "closed.delete",
            "params": [
                ["name": "closed", "argument": "closed"],
                ["name": "members", "argument": "members"],
                ["name": "workspace", "target": "workspace"],
                ["name": "all", "constant": false],
                ["name": "limit", "constant": 3],
            ],
        ],
    ]

    @Test func decodesTheRequestAndListOfARow() throws {
        let (requests, lists) = RustActionCatalog.catalogRequests([Self.row, ["id": "plain"]])
        let request = try #require(requests["closed.delete"])
        #expect(request.lane == .session)
        #expect(request.operation == "closed.delete")
        #expect(request.params.map(\.source) == [.argument("closed"), .argument("members"), .target(.workspace),
                                                 .constant(.bool(false)), .constant(.int(3))])
        #expect(requests["plain"] == nil)
        #expect(lists["op:closed.list"] == ActionCatalogListSource(lane: .session, operation: "closed.list", items: nil, value: "id", title: "name"))
        #expect(lists["x"] == nil)
        // A request that does not decode gets no binding (the conformance test names it).
        #expect(ActionCatalogRequest.decode(["lane": "cli", "operation": "x", "params": []]) == nil)
        #expect(ActionCatalogRequest.decode(["lane": "app", "operation": "x", "params": [["name": "y"]]]) == nil)
    }

    @Test func valuesTakeEachSource() throws {
        let (requests, _) = RustActionCatalog.catalogRequests([Self.row])
        let request = try #require(requests["closed.delete"])
        let descriptor = try #require(RustActionCatalog.descriptor(Self.row))
        let invocation = ActionInvocation(arguments: ["closed": .string("cl_1"), "members": .string("0, 2,")])
        let values = try request.values(arguments: descriptor.arguments, invocation: invocation) { $0 == .workspace ? "ws_9" : nil }.get()
        #expect(values == ["closed": .string("cl_1"), "members": .strings(["0", "2"]), "workspace": .string("ws_9"),
                           "all": .bool(false), "limit": .int(3)])
        // An omitted argument is left out; a missing target fails with its kind.
        let bare = try request.values(arguments: descriptor.arguments, invocation: ActionInvocation()) { _ in "ws_9" }.get()
        #expect(bare["closed"] == nil && bare["members"] == nil)
        let missing = request.values(arguments: descriptor.arguments, invocation: invocation) { _ in nil }
        #expect(missing == .failure(ActionCatalogRequest.MissingTarget(kind: .workspace)))
    }

    @Test func listRowsBecomeSuggestions() throws {
        let list = ActionCatalogListSource(lane: .session, operation: "closed.list", items: nil, value: "id", title: "name")
        let data = try JSONSerialization.data(withJSONObject: [["id": "cl_1", "name": "Tab"], ["id": "cl_2"], ["name": "no id"]])
        #expect(CatalogRequestHandlers.cases(from: data, list) == [ActionEnumCase(value: "cl_1", title: "Tab"), ActionEnumCase(value: "cl_2", title: "cl_2")])
        let nested = ActionCatalogListSource(lane: .app, operation: "errors.list", items: "entries", value: "fingerprint", title: "template")
        let wrapped = try JSONSerialization.data(withJSONObject: ["entries": [["fingerprint": "ab", "template": "x failed"]]])
        #expect(CatalogRequestHandlers.cases(from: wrapped, nested) == [ActionEnumCase(value: "ab", title: "x failed")])
    }

    /// A destructive request row asks before it runs (review of #43867: Clear Recently Closed
    /// ran unasked because no hand-written question listed it); a row that is not destructive,
    /// or names no request, is not asked about here.
    @Test func aDestructiveRequestRowAsks() throws {
        let (requests, _) = RustActionCatalog.catalogRequests([Self.row])
        let request = try #require(requests["closed.delete"])
        let clear = ActionDescriptor(id: "closed.clear", title: "Clear Recently Closed…", category: .window, destructive: true)
        let asked = try #require(CatalogRequestHandlers.confirmation(for: clear, request: request))
        #expect(asked.title == "Clear Recently Closed…")
        #expect(asked.button == "Clear Recently Closed")
        #expect(asked.body == CatalogRequestStrings.destructiveBody)
        let plain = ActionDescriptor(id: "errors.clear", title: "Clear Error Journal", category: .window)
        #expect(CatalogRequestHandlers.confirmation(for: plain, request: request) == nil)
        let handWritten = ActionDescriptor(id: "x.delete", title: "Delete X…", category: .window, destructive: true)
        #expect(CatalogRequestHandlers.confirmation(for: handWritten) == nil)
    }

    /// Default deny: a run relayed from another device never sends a catalog request.
    @Test func aRelayedRunIsRefused() {
        #expect(CatalogRequestHandlers.refusal(ActionInvocation(origin: .remote)) == CatalogRequestStrings.remote)
        for origin in ActionOrigin.allCases where origin != .remote {
            #expect(CatalogRequestHandlers.refusal(ActionInvocation(origin: origin)) == nil, "\(origin)")
        }
    }

    /// Every catalog row with a request has a handler once the app binds, and a row a
    /// hand-written handler already took keeps it.
    @Test func everyRequestRowIsBound() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let unbound = services.registry.unboundActionIDs().filter { ActionCatalog.requests[$0] != nil }
        #expect(unbound.isEmpty, "request rows without a handler: \(unbound.map(\.rawValue))")
        #expect(services.registry.duplicateBindings.isEmpty)
    }
}
