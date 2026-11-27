import Foundation

actor CmuxRuntimeDebugCaptureSender {
    private let maxInFlightRequests: Int
    private let sequence = CmuxRuntimeDebugCaptureSequence()
    private var inFlightRequests = 0

    init(maxInFlightRequests: Int) {
        self.maxInFlightRequests = maxInFlightRequests
    }

    func sendIfCapacityAvailable(
        configuration: CmuxRuntimeDebugCaptureConfiguration,
        hypothesisID: String,
        source: String,
        name: String,
        expected: String?,
        actual: String?,
        data: [String: Any]
    ) async {
        guard inFlightRequests < maxInFlightRequests else {
            return
        }
        inFlightRequests += 1
        defer {
            inFlightRequests -= 1
        }

        let sequenceNumber = await sequence.next()
        await Self.sendLog(
            configuration: configuration,
            sequenceNumber: sequenceNumber,
            hypothesisID: hypothesisID,
            source: source,
            name: name,
            expected: expected,
            actual: actual,
            data: data
        )
    }

    private static func sendLog(
        configuration: CmuxRuntimeDebugCaptureConfiguration,
        sequenceNumber: Int,
        hypothesisID: String,
        source: String,
        name: String,
        expected: String?,
        actual: String?,
        data: [String: Any]
    ) async {
        var payload: [String: Any] = [
            "session_id": configuration.sessionID,
            "hypothesis_id": hypothesisID,
            "service": "cmux-macos",
            "source": source,
            "name": name,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": ProcessInfo.processInfo.systemUptime * 1000,
            "seq": sequenceNumber,
            "data": data
        ]
        if let expected {
            payload["expected"] = expected
        }
        if let actual {
            payload["actual"] = actual
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/logs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.token, forHTTPHeaderField: "X-Debug-Token")
        request.httpBody = requestBody

        _ = try? await URLSession.shared.data(for: request)
    }
}
