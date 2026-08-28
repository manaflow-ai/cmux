import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarFocusBridge request handling")
@MainActor
struct CustomSidebarFocusBridgeTests {
    private let armedURL = URL(string: "http://127.0.0.1:8787/index.html")!

    private final class FocusRecorder {
        var requested: [UUID] = []
        var status: CustomSidebarFocusStatus = .focused
    }

    private func makeBridge(
        recorder: FocusRecorder,
        scope: CustomSidebarFocusScope? = nil
    ) -> CustomSidebarFocusBridge {
        let resolvedScope = scope ?? CustomSidebarFocusScope(source: .remote(armedURL))!
        let capability = CustomSidebarFocusCapability { workspaceID in
            recorder.requested.append(workspaceID)
            return recorder.status
        }
        return CustomSidebarFocusBridge(scope: resolvedScope, capability: capability)
    }

    private func resolve(
        _ bridge: CustomSidebarFocusBridge,
        body: Any,
        isMainFrame: Bool = true,
        scheme: String? = "http",
        host: String? = "127.0.0.1",
        port: Int? = 8787,
        webViewURL: URL? = URL(string: "http://127.0.0.1:8787/index.html")
    ) -> CustomSidebarFocusStatus? {
        bridge.resolve(
            messageBody: body,
            isMainFrame: isMainFrame,
            frameOriginScheme: scheme,
            frameOriginHost: host,
            frameOriginPort: port,
            webViewURL: webViewURL
        )
    }

    @Test("a well-formed request focuses the named workspace")
    func wellFormedRequestFocuses() {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)
        let workspaceID = UUID()

        let status = resolve(bridge, body: ["v": 1, "workspaceId": workspaceID.uuidString])

        #expect(status == .focused)
        #expect(recorder.requested == [workspaceID])
    }

    @Test(
        "each resolution reaches the page as its own status",
        arguments: [
            CustomSidebarFocusStatus.focused,
            CustomSidebarFocusStatus.notFound,
            CustomSidebarFocusStatus.unavailable,
        ]
    )
    func statusesRoundTrip(status: CustomSidebarFocusStatus) {
        let recorder = FocusRecorder()
        recorder.status = status
        let bridge = makeBridge(recorder: recorder)

        let resolved = resolve(bridge, body: ["v": 1, "workspaceId": UUID().uuidString])

        #expect(resolved == status)
        #expect(resolved?.replyBody["status"] as? String == status.rawValue)
        #expect(resolved?.replyBody["v"] as? Int == 1)
    }

    /// The malformed shapes, named so a failure says which one got through.
    ///
    /// A case rather than an inline `[String: Any]` because Swift Testing requires `Sendable`
    /// arguments and `Any` is not one.
    enum MalformedBody: String, Sendable, CaseIterable {
        case missingWorkspaceID
        case missingVersion
        case wrongVersion
        case versionAsString
        case versionAsBool
        case workspaceIDNotAUUID
        case workspaceIDNotAString
        case extraKey
        case empty

        var body: [String: Any] {
            let workspaceID = UUID().uuidString
            switch self {
            case .missingWorkspaceID: return ["v": 1]
            case .missingVersion: return ["workspaceId": workspaceID]
            case .wrongVersion: return ["v": 2, "workspaceId": workspaceID]
            case .versionAsString: return ["v": "1", "workspaceId": workspaceID]
            case .versionAsBool: return ["v": true, "workspaceId": workspaceID]
            case .workspaceIDNotAUUID: return ["v": 1, "workspaceId": "not-a-uuid"]
            case .workspaceIDNotAString: return ["v": 1, "workspaceId": 42]
            case .extraKey: return ["v": 1, "workspaceId": workspaceID, "focus": true]
            case .empty: return [:]
            }
        }
    }

    // Malformed input must never reach the focus closure: a rejection is a refusal to act, not an
    // action with a bad argument.
    @Test(
        "a body that is not exactly { v: 1, workspaceId } is rejected without acting",
        arguments: MalformedBody.allCases
    )
    func malformedBodiesAreRejected(malformed: MalformedBody) {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)

        #expect(resolve(bridge, body: malformed.body) == nil)
        #expect(recorder.requested.isEmpty)
    }

    @Test("a non-dictionary body is rejected without acting")
    func nonDictionaryBodyRejected() {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)

        #expect(resolve(bridge, body: "focus everything") == nil)
        #expect(recorder.requested.isEmpty)
    }

    @Test("a subframe cannot dispatch even with a perfect body")
    func subframeRejected() {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)

        #expect(resolve(bridge, body: ["v": 1, "workspaceId": UUID().uuidString], isMainFrame: false) == nil)
        #expect(recorder.requested.isEmpty)
    }

    @Test("a frame from another origin cannot dispatch")
    func foreignOriginRejected() {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)

        let status = resolve(
            bridge,
            body: ["v": 1, "workspaceId": UUID().uuidString],
            scheme: "https",
            host: "example.com",
            port: 443,
            webViewURL: URL(string: "https://example.com/")
        )

        #expect(status == nil)
        #expect(recorder.requested.isEmpty)
    }

    // The handler survives a document change, so a page that ends up somewhere else while the
    // registration is still live must fail the dispatch-time check rather than inherit the bridge.
    @Test("a view that has moved off the armed page cannot dispatch")
    func navigatedAwayRejected() {
        let recorder = FocusRecorder()
        let bridge = makeBridge(recorder: recorder)

        let status = resolve(
            bridge,
            body: ["v": 1, "workspaceId": UUID().uuidString],
            webViewURL: URL(string: "https://example.com/")
        )

        #expect(status == nil)
        #expect(recorder.requested.isEmpty)
    }

    // The capability is held by reference so a remount can replace the closure the page reaches
    // without the handler ever being unregistered.
    @Test("replacing the capability's closure changes what an already-installed bridge does")
    func capabilityClosureIsReplaceable() {
        let capability = CustomSidebarFocusCapability { _ in .unavailable }
        let bridge = CustomSidebarFocusBridge(
            scope: CustomSidebarFocusScope(source: .remote(armedURL))!,
            capability: capability
        )
        #expect(resolve(bridge, body: ["v": 1, "workspaceId": UUID().uuidString]) == .unavailable)

        capability.focus = { _ in .notFound }

        #expect(resolve(bridge, body: ["v": 1, "workspaceId": UUID().uuidString]) == .notFound)
    }
}
