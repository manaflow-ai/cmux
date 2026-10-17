import Foundation

/// Records the DevTools protocol events automation reads back from a
/// Chromium page: network requests (`Network.*`), console messages
/// (`Runtime.consoleAPICalled`) and page errors (`Runtime.exceptionThrown`).
///
/// The page feeds it every raw protocol message once automation turned
/// recording on; messages it does not need cost a short scan, not a parse.
/// Pure, so every rule is testable without Chromium.
///
/// Console entries and errors belong to the current document, as the
/// JavaScript bootstrap's logs do: a new main document
/// (`Runtime.executionContextsCleared`) clears them. Requests stay across
/// documents, the oldest dropped past ``networkRequestLimit``.
public struct BrowserProtocolTelemetryRecorder: Sendable {
    /// Requests kept per page.
    public static let networkRequestLimit = 500
    /// Console entries and errors kept per page (the bootstrap keeps as many).
    public static let logLimit = 512

    /// Console messages of the current document, oldest first.
    public private(set) var consoleEntries: [BrowserProtocolConsoleEntry] = []
    /// Page errors of the current document, oldest first.
    public private(set) var pageErrors: [BrowserProtocolPageError] = []
    /// When recording started (milliseconds since 1970); nil before.
    public var recordingStartedAtMS: Double?

    private var requests: [Int: BrowserProtocolNetworkRequest] = [:]
    private var requestOrder: [Int] = []
    /// The entry of each request id still waiting for its end.
    private var openRequests: [String: Int] = [:]
    private var nextSerial = 0

    static let recordedMethods: Set<String> = [
        "Network.requestWillBeSent", "Network.responseReceived", "Network.requestServedFromCache",
        "Network.loadingFinished", "Network.loadingFailed",
        "Runtime.consoleAPICalled", "Runtime.exceptionThrown", "Runtime.exceptionRevoked",
        "Runtime.executionContextsCleared",
    ]

    public init() {}

    /// Requests, oldest first.
    public var networkRequests: [BrowserProtocolNetworkRequest] {
        requestOrder.compactMap { requests[$0] }
    }

    public mutating func clearConsole() { consoleEntries.removeAll() }
    public mutating func clearErrors() { pageErrors.removeAll() }
    public mutating func clearNetwork() {
        requests.removeAll()
        requestOrder.removeAll()
        openRequests.removeAll()
    }

    /// Records one raw protocol message. Returns true when it changed a log.
    @discardableResult
    public mutating func ingest(_ message: String) -> Bool {
        if let method = Self.leadingMethod(in: message), method.contains("."),
           !Self.recordedMethods.contains(String(method)) {
            return false
        }
        guard let data = message.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["id"] == nil,
              let method = object["method"] as? String,
              Self.recordedMethods.contains(method) else { return false }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "Network.requestWillBeSent": requestWillBeSent(params)
        case "Network.responseReceived": return responseReceived(params)
        case "Network.requestServedFromCache": return update(params) { $0.fromCache = true }
        case "Network.loadingFinished": return loadingEnded(params, failed: false)
        case "Network.loadingFailed": return loadingEnded(params, failed: true)
        case "Runtime.consoleAPICalled": return consoleAPICalled(params)
        case "Runtime.exceptionThrown": exceptionThrown(params)
        case "Runtime.exceptionRevoked":
            guard let id = Self.int(params["exceptionId"]) else { return false }
            pageErrors.removeAll { $0.exceptionID == id }
        case "Runtime.executionContextsCleared":
            consoleEntries.removeAll()
            pageErrors.removeAll()
        default: return false
        }
        return true
    }

    // MARK: Network

    private mutating func requestWillBeSent(_ params: [String: Any]) {
        guard let requestID = params["requestId"] as? String else { return }
        // A redirect: the hop ends with the redirect's response, the same
        // request id continues as a new entry.
        if let redirect = params["redirectResponse"] as? [String: Any] {
            _ = update(params) { request in
                Self.apply(response: redirect, to: &request)
                request.state = .redirected
                request.durationMS = Self.duration(request, end: params["timestamp"])
            }
            openRequests.removeValue(forKey: requestID)
        }
        let request = params["request"] as? [String: Any] ?? [:]
        let wallTime = Self.double(params["wallTime"]) ?? Date().timeIntervalSince1970
        var entry = BrowserProtocolNetworkRequest(
            requestID: requestID,
            url: request["url"] as? String ?? "",
            method: request["method"] as? String ?? "GET",
            resourceType: (params["type"] as? String ?? "Other").lowercased(),
            timestampMS: wallTime * 1000
        )
        entry.startMonotonic = Self.double(params["timestamp"])
        let serial = nextSerial
        nextSerial += 1
        requests[serial] = entry
        requestOrder.append(serial)
        openRequests[requestID] = serial
        if requestOrder.count > Self.networkRequestLimit {
            let dropped = requestOrder.removeFirst()
            if let gone = requests.removeValue(forKey: dropped), openRequests[gone.requestID] == dropped {
                openRequests.removeValue(forKey: gone.requestID)
            }
        }
    }

    private mutating func responseReceived(_ params: [String: Any]) -> Bool {
        guard let response = params["response"] as? [String: Any] else { return false }
        return update(params) { Self.apply(response: response, to: &$0) }
    }

    private mutating func loadingEnded(_ params: [String: Any], failed: Bool) -> Bool {
        guard let requestID = params["requestId"] as? String else { return false }
        let changed = update(params) { request in
            request.state = failed ? .failed : .finished
            if failed {
                request.errorText = params["errorText"] as? String ?? ""
                request.canceled = params["canceled"] as? Bool ?? false
            } else {
                request.encodedDataLength = Self.double(params["encodedDataLength"])
            }
            request.durationMS = Self.duration(request, end: params["timestamp"])
        }
        openRequests.removeValue(forKey: requestID)
        return changed
    }

    /// Changes the open entry of the event's request id; false when unknown.
    private mutating func update(
        _ params: [String: Any],
        _ change: (inout BrowserProtocolNetworkRequest) -> Void
    ) -> Bool {
        guard let requestID = params["requestId"] as? String,
              let serial = openRequests[requestID],
              var request = requests[serial] else { return false }
        change(&request)
        requests[serial] = request
        return true
    }

    private static func apply(response: [String: Any], to request: inout BrowserProtocolNetworkRequest) {
        request.status = int(response["status"])
        request.statusText = response["statusText"] as? String
        request.mimeType = response["mimeType"] as? String
        request.remoteAddress = response["remoteIPAddress"] as? String
        if response["fromDiskCache"] as? Bool == true || response["fromPrefetchCache"] as? Bool == true {
            request.fromCache = true
        }
    }

    private static func duration(_ request: BrowserProtocolNetworkRequest, end: Any?) -> Double? {
        guard let start = request.startMonotonic, let end = double(end), end >= start else { return nil }
        return (end - start) * 1000
    }

    // MARK: Console and errors

    private mutating func consoleAPICalled(_ params: [String: Any]) -> Bool {
        let type = params["type"] as? String ?? "log"
        let level: String
        switch type {
        case "log", "info", "error", "debug": level = type
        case "warning": level = "warn"
        case "assert": level = "error"
        case "clear", "endGroup", "profile", "profileEnd": return false
        default: level = "log"
        }
        let args = params["args"] as? [[String: Any]] ?? []
        let text = args.map(BrowserProtocolRemoteObjectText.text(of:)).joined(separator: " ")
        let time = Self.double(params["timestamp"]) ?? Date().timeIntervalSince1970 * 1000
        Self.append(BrowserProtocolConsoleEntry(level: level, text: text, timestampMS: time), to: &consoleEntries)
        return true
    }

    private mutating func exceptionThrown(_ params: [String: Any]) {
        let details = params["exceptionDetails"] as? [String: Any] ?? [:]
        let prefix = details["text"] as? String ?? "Uncaught"
        var message = prefix
        if let exception = details["exception"] as? [String: Any] {
            let description = BrowserProtocolRemoteObjectText.text(of: exception)
            let firstLine = description.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            if !firstLine.isEmpty { message = prefix.isEmpty ? firstLine : "\(prefix) \(firstLine)" }
        }
        let line = Self.int(details["lineNumber"]).map { $0 + 1 } ?? 0
        let column = Self.int(details["columnNumber"]).map { $0 + 1 } ?? 0
        let error = BrowserProtocolPageError(
            message: message,
            source: details["url"] as? String ?? "",
            line: line,
            column: column,
            timestampMS: Self.double(params["timestamp"]) ?? Date().timeIntervalSince1970 * 1000,
            exceptionID: Self.int(details["exceptionId"])
        )
        Self.append(error, to: &pageErrors)
    }

    private static func append<T>(_ item: T, to list: inout [T]) {
        list.append(item)
        if list.count > logLimit { list.removeFirst(list.count - logLimit) }
    }

    // MARK: Scanning

    /// The value of the first `"method":"..."` in `message`. Chromium writes
    /// an event's `method` first, so this names the event without a parse;
    /// a nested `method` (a request's `GET`) has no dot and is parsed.
    static func leadingMethod(in message: String) -> Substring? {
        guard let key = message.range(of: #""method":""#) else { return nil }
        let rest = message[key.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return rest[..<end]
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
