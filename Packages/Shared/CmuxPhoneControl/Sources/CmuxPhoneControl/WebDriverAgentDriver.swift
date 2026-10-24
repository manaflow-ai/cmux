import Foundation

/// Adapter for a signed XCTest/WebDriverAgent runner. The runner must be
/// forwarded to loopback (normally localhost:8100); this type never opens a
/// device port or exposes the runner on the network.
public actor WebDriverAgentDriver: PhoneDriver {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let deviceID: String
        public let name: String
        public let model: String
        public let osVersion: String
        public let geometry: PhoneDisplayGeometry

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8100")!,
            deviceID: String = "wda-device",
            name: String = "Developer iPhone",
            model: String = "iPhone",
            osVersion: String = "unknown",
            geometry: PhoneDisplayGeometry = .init(width: 390, height: 844, scale: 3)
        ) {
            self.baseURL = baseURL
            self.deviceID = deviceID
            self.name = name
            self.model = model
            self.osVersion = osVersion
            self.geometry = geometry
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession
    private var currentGeometry: PhoneDisplayGeometry
    private var wdaSessionID: String?
    private var sequence: UInt64 = 0

    public init(configuration: Configuration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        self.urlSession = urlSession ?? URLSession(
            configuration: .ephemeral,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
        currentGeometry = configuration.geometry
    }

    public func device() async throws -> PhoneDevice {
        let status = try await request(path: "/status", method: "GET")
        guard let ready = status["value"]?["ready"]?.boolValue else {
            throw PhoneDriverError.malformedResponse("WDA status did not contain a ready flag")
        }
        guard ready else {
            throw PhoneDriverError.unavailable("WebDriverAgent is not ready")
        }
        _ = try await ensureSession()
        try await refreshGeometry()
        return PhoneDevice(
            id: configuration.deviceID,
            name: configuration.name,
            model: configuration.model,
            osVersion: configuration.osVersion,
            source: .webDriverAgent,
            state: .available,
            geometry: currentGeometry,
            capabilities: .init(
                screenSnapshot: true,
                screenStream: false,
                accessibilityTree: true,
                tap: true,
                swipe: true,
                typing: true,
                physicalButtons: true
            )
        )
    }

    private static func validatedDimension(_ value: Double) -> Int? {
        guard value.isFinite, value >= 1, value.rounded() == value,
              value <= Double(Int.max)
        else { return nil }
        return Int(exactly: value)
    }

    private func refreshGeometry() async throws {
        let sizeResponse = try await sessionRequest(path: "/window/size", method: "GET")
        guard let widthValue = sizeResponse["value"]?["width"]?.doubleValue,
              let heightValue = sizeResponse["value"]?["height"]?.doubleValue,
              let width = Self.validatedDimension(widthValue),
              let height = Self.validatedDimension(heightValue)
        else {
            throw PhoneDriverError.malformedResponse("WDA window size was not a finite positive integer")
        }
        currentGeometry = PhoneDisplayGeometry(
            width: width,
            height: height,
            scale: currentGeometry.scale,
            orientation: currentGeometry.orientation,
            safeInsets: currentGeometry.safeInsets
        )
    }

    public func snapshot() async throws -> PhoneScreenFrame {
        try await refreshGeometry()
        let response = try await sessionRequest(path: "/screenshot", method: "GET")
        guard let base64 = response["value"]?.stringValue,
              let data = Data(base64Encoded: base64)
        else {
            throw PhoneDriverError.malformedResponse("WDA screenshot did not contain base64 PNG data")
        }
        sequence += 1
        return PhoneScreenFrame(
            sequence: sequence,
            width: currentGeometry.width,
            height: currentGeometry.height,
            orientation: currentGeometry.orientation,
            data: data
        )
    }

    public func accessibilityTree() async throws -> PhoneUIElement? {
        try await refreshGeometry()
        let response = try await sessionRequest(path: "/source?format=json", method: "GET")
        guard let value = response["value"] else {
            throw PhoneDriverError.malformedResponse("WDA source did not contain a value")
        }
        return parseElement(value, path: "root")
    }

    public func perform(_ action: PhoneActionRequest) async throws -> PhoneActionReceipt {
        try action.validated()
        try await refreshGeometry()
        let geometry = currentGeometry
        let response: PhoneJSONValue
        switch action.kind {
        case .tap:
            guard let point = action.point else {
                throw PhoneError(code: "invalid_action", message: "tap requires point")
            }
            response = try await sessionRequest(
                path: "/wda/tap",
                method: "POST",
                body: .object([
                    "x": .number(point.x * Double(geometry.width)),
                    "y": .number(point.y * Double(geometry.height)),
                ])
            )
        case .swipe:
            guard let start = action.point, let end = action.endPoint else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
            response = try await sessionRequest(
                path: "/wda/dragfromtoforduration",
                method: "POST",
                body: .object([
                    "fromX": .number(start.x * Double(geometry.width)),
                    "fromY": .number(start.y * Double(geometry.height)),
                    "toX": .number(end.x * Double(geometry.width)),
                    "toY": .number(end.y * Double(geometry.height)),
                    "duration": .number(Double(action.durationMilliseconds ?? 250) / 1000),
                ])
            )
        case .longPress:
            guard let point = action.point else {
                throw PhoneError(code: "invalid_action", message: "long_press requires point")
            }
            response = try await sessionRequest(
                path: "/wda/touchAndHold",
                method: "POST",
                body: .object([
                    "x": .number(point.x * Double(geometry.width)),
                    "y": .number(point.y * Double(geometry.height)),
                    "duration": .number(Double(action.durationMilliseconds ?? 800) / 1000),
                ])
            )
        case .type:
            guard let text = action.text, !text.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "type requires text")
            }
            response = try await sessionRequest(
                path: "/wda/keys",
                method: "POST",
                body: .object(["value": .array([.string(text)])])
            )
        case .press:
            guard let button = action.button else {
                throw PhoneError(code: "invalid_action", message: "press requires button")
            }
            response = try await sessionRequest(
                path: "/wda/pressButton",
                method: "POST",
                body: .object(["name": .string(button)])
            )
        }
        _ = response
        sequence += 1
        return PhoneActionReceipt(
            actionID: action.actionID,
            accepted: true,
            screenSequence: sequence,
            detail: "WebDriverAgent accepted the action"
        )
    }

    private func ensureSession() async throws -> String {
        if let wdaSessionID { return wdaSessionID }
        let response = try await request(
            path: "/session",
            method: "POST",
            body: .object([
                "capabilities": .object([
                    "alwaysMatch": .object([
                        "platformName": .string("iOS"),
                        "automationName": .string("XCUITest"),
                        "deviceName": .string(configuration.name),
                    ])
                ])
            ])
        )
        let sessionID = response["sessionId"]?.stringValue
            ?? response["session_id"]?.stringValue
            ?? response["value"]?["sessionId"]?.stringValue
            ?? response["value"]?["session_id"]?.stringValue
        guard let sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 256 else {
            throw PhoneDriverError.malformedResponse("WDA session response did not contain a valid session id")
        }
        wdaSessionID = sessionID
        return sessionID
    }

    private func sessionRequest(
        path: String,
        method: String,
        body: PhoneJSONValue? = nil
    ) async throws -> PhoneJSONValue {
        let sessionID = try await ensureSession()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard let escaped = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PhoneDriverError.transport("invalid WDA session id")
        }
        return try await request(path: "/session/\(escaped)\(path)", method: method, body: body)
    }

    private func request(
        path: String,
        method: String,
        body: PhoneJSONValue? = nil
    ) async throws -> PhoneJSONValue {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw PhoneDriverError.transport("invalid WDA base URL")
        }
        if let question = path.firstIndex(of: "?") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/" + String(path[..<question]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.percentEncodedQuery = String(path[path.index(after: question)...])
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let url = components.url else {
            throw PhoneDriverError.transport("invalid WDA endpoint")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PhoneDriverError.transport("WDA endpoint must be loopback HTTP(S)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PhoneDriverError.transport("WDA returned a non-HTTP response")
        }
        let maxResponseBytes = PhoneProtocol.maxResponseLineBytes
        if http.expectedContentLength > Int64(maxResponseBytes) {
            throw PhoneDriverError.malformedResponse("WDA response exceeded the bounded response size")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PhoneDriverError.transport("WDA HTTP status \(http.statusCode)")
        }
        guard http.url?.host?.lowercased() == url.host?.lowercased() else {
            throw PhoneDriverError.transport("WDA redirect left the loopback endpoint")
        }
        var data = Data()
        data.reserveCapacity(min(
            http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 4 * 1024,
            maxResponseBytes
        ))
        for try await byte in bytes {
            guard data.count < maxResponseBytes else {
                throw PhoneDriverError.malformedResponse("WDA response exceeded the bounded response size")
            }
            data.append(byte)
        }
        let decoded = try? JSONDecoder().decode(PhoneJSONValue.self, from: data)
        guard let decoded else {
            throw PhoneDriverError.malformedResponse("WDA returned invalid JSON")
        }
        if let error = decoded["value"]?["error"]?.stringValue {
            throw PhoneDriverError.transport("WDA error: \(error)")
        }
        return decoded
    }

    private func parseElement(_ value: PhoneJSONValue, path: String) -> PhoneUIElement? {
        guard case .object(let object) = value else { return nil }
        let frame = object["frame"] ?? object["rect"]
        let bounds = parseBounds(frame)
        let label = object["label"]?.stringValue ?? object["name"]?.stringValue
        let role = object["type"]?.stringValue ?? "element"
        let children: [PhoneUIElement] = (object["children"]?.arrayValue ?? []).enumerated().compactMap {
            parseElement($0.element, path: "\(path).\($0.offset)")
        }
        return PhoneUIElement(
            id: path,
            role: role,
            label: label,
            value: object["value"]?.stringValue,
            enabled: object["isEnabled"]?.boolValue ?? true,
            visible: object["isVisible"]?.boolValue ?? true,
            bounds: bounds,
            actions: ["tap"],
            children: children
        )
    }

    private func parseBounds(_ value: PhoneJSONValue?) -> PhoneUIElement.Bounds {
        guard let value,
              let x = value["x"]?.doubleValue,
              let y = value["y"]?.doubleValue,
              let width = (value["width"] ?? value["w"])?.doubleValue,
              let height = (value["height"] ?? value["h"])?.doubleValue
        else { return .init(x: 0, y: 0, width: 0, height: 0) }
        return .init(
            x: x / Double(currentGeometry.width),
            y: y / Double(currentGeometry.height),
            width: width / Double(currentGeometry.width),
            height: height / Double(currentGeometry.height)
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private extension PhoneJSONValue {
    var arrayValue: [PhoneJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
}
