@preconcurrency import Foundation

/// Pauses top-level document requests until cmux has evaluated navigation policy.
///
/// Chromium's page target does not expose a synchronous request delegate. The
/// DevTools `Fetch` domain provides the equivalent boundary: document requests
/// remain paused while the main-actor policy handler decides whether they may
/// continue, so redirects and page-initiated links cannot bypass cmux policy.
actor ChromiumNavigationInterceptor {
    private let policyHandler: BrowserEngineNavigationPolicyHandler?
    private var mainFrameID: String?

    /// Creates an interceptor with the policy owned by the app composition root.
    ///
    /// - Parameter policyHandler: Main-actor decision closure, or `nil` to leave
    ///   Chromium request handling untouched.
    init(policyHandler: BrowserEngineNavigationPolicyHandler?) {
        self.policyHandler = policyHandler
    }

    /// Enables top-level document interception on one CDP connection.
    ///
    /// - Parameter connection: The page-scoped Chromium connection.
    /// - Throws: A CDP transport or protocol error.
    func install(connection: ChromiumCDPConnection) async throws {
        guard policyHandler != nil else { return }
        if let frameTree = try? await connection.send(method: "Page.getFrameTree") {
            recordMainFrame(from: frameTree)
        }
        _ = try await connection.send(
            method: "Fetch.enable",
            parameters: .object([
                "patterns": .array([
                    .object([
                        "urlPattern": .string("*"),
                        "resourceType": .string("Document"),
                        "requestStage": .string("Request"),
                    ])
                ])
            ])
        )
    }

    /// Handles one CDP event and returns whether the interceptor consumed it.
    ///
    /// - Parameters:
    ///   - event: Event delivered by the page connection.
    ///   - connection: The connection that owns the paused request.
    /// - Returns: `true` when the event was fully handled.
    /// - Throws: A CDP command error when a paused request cannot be resumed.
    func handle(
        _ event: CDPEvent,
        connection: ChromiumCDPConnection
    ) async throws -> Bool {
        if event.method == "Page.frameNavigated" {
            recordMainFrame(from: event.params)
            return false
        }
        guard event.method == "Fetch.requestPaused" else { return false }
        guard let requestID = event.params?["requestId"]?.stringValue else {
            return true
        }

        guard event.params?["resourceType"]?.stringValue == "Document",
              await isMainFrame(event.params, connection: connection),
              let request = request(from: event.params?["request"]) else {
            try await continueRequest(requestID, connection: connection)
            return true
        }

        let policyRequest = BrowserEngineNavigationRequest(
            request: request,
            disposition: .currentTab
        )
        let decision = await policyHandler?(policyRequest) ?? .allow
        switch decision {
        case .allow:
            try await continueRequest(requestID, connection: connection)
        case .cancel:
            _ = try await connection.send(
                method: "Fetch.failRequest",
                parameters: .object([
                    "requestId": .string(requestID),
                    "errorReason": .string("Aborted"),
                ])
            )
        }
        return true
    }

    private func isMainFrame(
        _ params: CDPValue?,
        connection: ChromiumCDPConnection
    ) async -> Bool {
        guard case .object(let object) = params,
              let frameID = object["frameId"]?.stringValue else {
            return false
        }
        if mainFrameID == nil,
           let frameTree = try? await connection.send(method: "Page.getFrameTree") {
            recordMainFrame(from: frameTree)
        }
        guard let mainFrameID else {
            // If Chromium cannot answer while the request is paused, apply the
            // policy to the document rather than allowing an unknown top-level
            // redirect to bypass the boundary.
            return !frameID.isEmpty
        }
        return frameID == mainFrameID
    }

    private func recordMainFrame(from value: CDPValue?) {
        guard let frame = mainFrame(from: value),
              let frameID = frame["id"]?.stringValue,
              !frameID.isEmpty else { return }
        mainFrameID = frameID
    }

    private func mainFrame(from value: CDPValue?) -> [String: CDPValue]? {
        guard case .object(let root) = value else { return nil }
        if let frameTree = root["frameTree"],
           case .object(let tree) = frameTree,
           case .object(let frame)? = tree["frame"] {
            return frame
        }
        if case .object(let frame)? = root["frame"],
           frame["parentId"] == nil {
            return frame
        }
        if root["parentId"] == nil, root["id"]?.stringValue != nil {
            return root
        }
        return nil
    }

    private func request(from value: CDPValue?) -> URLRequest? {
        guard case .object(let payload) = value,
              let rawURL = payload["url"]?.stringValue,
              let url = URL(string: rawURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        if let method = payload["method"]?.stringValue, !method.isEmpty {
            request.httpMethod = method
        }
        if case .object(let headers)? = payload["headers"] {
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
        connection: ChromiumCDPConnection
    ) async throws {
        _ = try await connection.send(
            method: "Fetch.continueRequest",
            parameters: .object(["requestId": .string(requestID)])
        )
    }
}
