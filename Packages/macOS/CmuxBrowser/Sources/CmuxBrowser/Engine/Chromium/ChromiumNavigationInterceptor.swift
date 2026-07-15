import Foundation

/// Applies cmux navigation policy while Chromium document requests and child pages are paused.
@MainActor
final class ChromiumNavigationInterceptor {
    private let targetID: String
    private let mainFrameIdentity: ChromiumMainFrameIdentity
    var policyHandler: BrowserEngineNavigationPolicyHandler?

    init(
        targetID: String,
        policyHandler: BrowserEngineNavigationPolicyHandler?,
        mainFrameIdentity: ChromiumMainFrameIdentity = ChromiumMainFrameIdentity()
    ) {
        self.targetID = targetID
        self.policyHandler = policyHandler
        self.mainFrameIdentity = mainFrameIdentity
    }

    func install(connection: CDPConnection, sessionID: String) async throws {
        let frameTree = try await connection.send(
            method: "Page.getFrameTree",
            sessionID: sessionID
        )
        mainFrameIdentity.record(frameTree: frameTree)

        _ = try await connection.send(
            method: "Fetch.enable",
            parameters: [
                "patterns": .array([
                    .object([
                        "urlPattern": .string("*"),
                        "resourceType": .string("Document"),
                        "requestStage": .string("Request"),
                    ]),
                ]),
            ],
            sessionID: sessionID
        )
        _ = try await connection.send(
            method: "Target.setAutoAttach",
            parameters: [
                "autoAttach": .bool(true),
                "waitForDebuggerOnStart": .bool(true),
                "flatten": .bool(true),
            ],
            sessionID: sessionID
        )
    }

    func handle(
        _ event: CDPEvent,
        connection: CDPConnection,
        sessionID: String
    ) async throws -> Bool {
        switch event.method {
        case "Fetch.requestPaused":
            try await handlePausedRequest(event, connection: connection, sessionID: sessionID)
            return true
        case "Page.windowOpen":
            routeWindowOpen(event)
            return true
        case "Target.attachedToTarget":
            return try await handleAttachedTarget(event, connection: connection)
        case "Page.frameNavigated":
            mainFrameIdentity.observe(event)
            return false
        default:
            return false
        }
    }

    private func handlePausedRequest(
        _ event: CDPEvent,
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        guard let requestID = event.parameters["requestId"]?.stringValue else {
            throw BrowserEngineSessionError.chromiumProtocol(
                "Chromium paused a request without an identifier."
            )
        }
        guard event.parameters["resourceType"]?.stringValue == "Document",
              mainFrameIdentity.matches(frameID: event.parameters["frameId"]?.stringValue),
              let request = navigationRequest(from: event.parameters["request"]?.objectValue) else {
            try await continueRequest(requestID, connection: connection, sessionID: sessionID)
            return
        }

        let policyRequest = BrowserEngineNavigationRequest(
            request: request,
            disposition: .currentTab
        )
        switch policyHandler?(policyRequest) ?? .allow {
        case .allow:
            try await continueRequest(requestID, connection: connection, sessionID: sessionID)
        case .cancel:
            _ = try await connection.send(
                method: "Fetch.failRequest",
                parameters: [
                    "requestId": .string(requestID),
                    "errorReason": .string("Aborted"),
                ],
                sessionID: sessionID
            )
        }
    }

    private func routeWindowOpen(_ event: CDPEvent) {
        guard let rawURL = event.parameters["url"]?.stringValue,
              let url = URL(string: rawURL) else {
            return
        }
        _ = policyHandler?(BrowserEngineNavigationRequest(
            request: URLRequest(url: url),
            disposition: .newTab
        ))
    }

    private func handleAttachedTarget(
        _ event: CDPEvent,
        connection: CDPConnection
    ) async throws -> Bool {
        guard let childSessionID = event.parameters["sessionId"]?.stringValue,
              let targetInfo = event.parameters["targetInfo"]?.objectValue else {
            return false
        }
        let isOwnedPage = targetInfo["type"]?.stringValue == "page" &&
            targetInfo["openerId"]?.stringValue == targetID
        if isOwnedPage, let childTargetID = targetInfo["targetId"]?.stringValue {
            _ = try await connection.send(
                method: "Target.closeTarget",
                parameters: ["targetId": .string(childTargetID)]
            )
        } else {
            _ = try await connection.send(
                method: "Runtime.runIfWaitingForDebugger",
                sessionID: childSessionID
            )
        }
        return true
    }

    private func navigationRequest(
        from payload: [String: CDPJSONValue]?
    ) -> URLRequest? {
        guard let payload,
              let rawURL = payload["url"]?.stringValue,
              let url = URL(string: rawURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        if let method = payload["method"]?.stringValue, !method.isEmpty {
            request.httpMethod = method
        }
        if let headers = payload["headers"]?.objectValue {
            for (field, value) in headers {
                guard let stringValue = value.stringValue else { continue }
                request.setValue(stringValue, forHTTPHeaderField: field)
            }
        }
        if let postData = payload["postData"]?.stringValue {
            request.httpBody = Data(postData.utf8)
        }
        return request
    }

    private func continueRequest(
        _ requestID: String,
        connection: CDPConnection,
        sessionID: String
    ) async throws {
        _ = try await connection.send(
            method: "Fetch.continueRequest",
            parameters: ["requestId": .string(requestID)],
            sessionID: sessionID
        )
    }
}
