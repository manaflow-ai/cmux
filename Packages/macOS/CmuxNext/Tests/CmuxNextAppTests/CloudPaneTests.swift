import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// u2861: "Open Cloud as Pane" said "needs the Cloud panel as a pane (not in cmux-next yet)". The
/// Cloud page is now a pane tab: the action runs (palette, Window menu, `cmux pane open-cloud-as`,
/// MCP), a Cloud page provider is registered, and the page's `cmux.cloud.` calls reach the Cloud app
/// server instead of answering "not available yet".
@MainActor @Suite(.serialized)
struct CloudPaneTests {
    /// One Cloud app server op as the provider sent it.
    struct SentOp: Equatable, Sendable {
        var op: String
        var args: CmuxNextDaemon.JSONValue
        var key: String?
        var origin: AppsRunRequest.Origin
    }

    actor Server {
        var sent: [SentOp] = []
        var answers: [String: CmuxNextDaemon.JSONValue]
        var failure: CloudAppOpFailure?

        init(answers: [String: CmuxNextDaemon.JSONValue]) { self.answers = answers }

        func run(_ op: SentOp) throws -> CmuxNextDaemon.JSONValue {
            sent.append(op)
            if let failure { throw failure }
            return answers[op.op] ?? .object([:])
        }

        func fail(with failure: CloudAppOpFailure) { self.failure = failure }
        func answer(_ op: String, _ value: CmuxNextDaemon.JSONValue) { answers[op] = value }
    }

    /// What a callback saw (a reference, so the main-actor callbacks can append to it). Two
    /// concrete boxes, not one generic class: swift-frontend 6.3.3 -O crashed in EarlyPerfInliner on
    /// the implicit deinit of a generic main-actor class (the Release test build).
    @MainActor final class SeenValues {
        var items: [CmuxNextSettings.JSONValue] = []
    }

    @MainActor final class SeenFlags {
        var items: [Bool] = []
    }

    static func provider(_ server: Server, signIn: @escaping @MainActor () async -> Bool = { false }) -> CloudPageProvider {
        CloudPageProvider(op: { op, args, key, origin in
            try await server.run(SentOp(op: op, args: args, key: key, origin: origin))
        }, signIn: signIn)
    }

    static let page = PageCallContext(page: PageDescriptor.cloud.id)
    static let confirmed = PageCallContext(page: PageDescriptor.cloud.id, origin: "user", confirmed: true)

    @Test func openCloudAsPaneIsAvailableAndRegistersTheCloudPage() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.openCloudPane") == nil,
                "Open Cloud as Pane still refuses: \(services.registry.unavailableReason(for: "palette.openCloudPane") ?? "")")
        let provider = services.pages.provider(InternalPageID(rawValue: "cloud"))
        #expect(provider != nil, "no Cloud page tab provider")
        #expect(provider?.symbol == "cloud")
    }

    @Test func aPageReadRunsTheServerOpAsScriptWithNoKey() async throws {
        let server = Server(answers: ["cloud.machine.list": .object(["machines": .array([]), "revision": .number(3)])])
        let answer = try await Self.provider(server).call("cmux.cloud.machine.list", params: ["cursor": .string("c1")],
                                                         context: Self.page)
        #expect(answer["revision"]?.intValue == 3)
        #expect(await server.sent == [SentOp(op: "cloud.machine.list", args: .object(["cursor": .string("c1")]), key: nil, origin: .script)])
    }

    @Test func aConfirmedMutationMovesItsKeyAndRunsAsTheUser() async throws {
        let server = Server(answers: ["cloud.machine.resize": .object(["machine": .object(["id": .string("m1")]), "revision": .number(5)])])
        _ = try await Self.provider(server).call(
            "cmux.cloud.machine.resize",
            params: ["machine": .string("m1"), "size": .object(["memory_mb": .number(8192)]), "idempotency_key": .string("k1")],
            context: Self.confirmed)
        let sent = try #require(await server.sent.first)
        #expect(sent.op == "cloud.machine.resize")
        #expect(sent.key == "k1")
        #expect(sent.origin == .user)
        #expect(sent.args["idempotency_key"] == nil)
        #expect(sent.args["machine"]?.stringValue == "m1")
    }

    @Test func theWatchStreamCarriesEachMutationAndDelete() async throws {
        let server = Server(answers: [
            "cloud.machine.watch": .object(["revision": .number(4)]),
            "cloud.machine.start": .object(["machine": .object(["id": .string("m1"), "status": .string("running")]), "revision": .number(7)]),
            "cloud.machine.delete": .object(["deleted": .bool(true)]),
        ])
        let provider = Self.provider(server)
        let seen = SeenValues()
        let subscription = try await provider.subscribe(CloudPageProvider.watchStream, filter: .object([:]), context: Self.page) {
            seen.items.append($0)
        }
        #expect(provider.watcherCount == 1)
        _ = try await provider.call("cmux.cloud.machine.start", params: ["machine": .string("m1"), "idempotency_key": .string("k2")],
                                    context: Self.page)
        #expect(seen.items.count == 1)
        #expect(seen.items.first?["type"]?.stringValue == "upsert")
        #expect(seen.items.first?["revision"]?.intValue == 7)
        #expect(seen.items.first?["machine"]?["status"]?.stringValue == "running")

        await server.answer("cloud.machine.watch", .object(["revision": .number(9)]))
        _ = try await provider.call("cmux.cloud.machine.delete", params: ["machine": .string("m1"), "idempotency_key": .string("k3")],
                                    context: Self.confirmed)
        #expect(seen.items.count == 2)
        #expect(seen.items.last?["type"]?.stringValue == "removed")
        #expect(seen.items.last?["id"]?.stringValue == "m1")
        #expect(seen.items.last?["revision"]?.intValue == 9)

        subscription.cancel()
        #expect(provider.watcherCount == 0)
    }

    @Test func aServerRefusalIsThePagesErrorWithTheSameCode() async throws {
        let server = Server(answers: [:])
        await server.fail(with: CloudAppOpFailure(code: "cmux.cloud.quota_exceeded", message: "limit reached",
                                                  details: .object(["limit": .number(2)])))
        do {
            _ = try await Self.provider(server).call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
            Issue.record("a refused op answered")
        } catch let error as PageError {
            #expect(error.code == "cmux.cloud.quota_exceeded")
            #expect(error.message == "limit reached")
            #expect(error.details?["limit"]?.intValue == 2)
        }
    }

    /// The daemon's "needs the cmux Mac app connected" (no provider) is the page's disconnected
    /// state with Retry, not an error banner over a list that never loads.
    @Test(arguments: ["provider.unavailable", "unavailable", "cmux.cloud.relay_unavailable"])
    func aDownLinkIsThePagesTransportError(code: String) async throws {
        let server = Server(answers: [:])
        await server.fail(with: CloudAppOpFailure(code: code, message: "needs the cmux Mac app connected"))
        do {
            _ = try await Self.provider(server).call("cmux.cloud.auth.status", params: .object([:]), context: Self.page)
            Issue.record("a down link answered")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.transport")
            #expect(error.retryable)
        }
    }

    @Test func signInRunsTheAppsSignInOnlyAfterTheSheet() async throws {
        let ran = SeenFlags()
        let provider = Self.provider(Server(answers: [:])) {
            ran.items.append(true)
            return true
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.cloud.auth.sign_in", params: .object([:]), context: Self.page)
        }
        #expect(ran.items.isEmpty)
        let answer = try await provider.call("cmux.cloud.auth.sign_in", params: .object([:]), context: Self.confirmed)
        #expect(ran.items.count == 1)
        #expect(answer["signed_in"]?.boolValue == true)
    }

    @Test func anotherNamespaceIsRefused() async {
        await #expect(throws: PageError.self) {
            _ = try await Self.provider(Server(answers: [:])).call("cmux.settings.get", params: .object([:]), context: Self.page)
        }
    }
}
