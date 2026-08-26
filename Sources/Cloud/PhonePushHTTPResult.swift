import Foundation

/// Truthful result of one Mac-to-push-API request.
enum PhonePushHTTPResult: Equatable, Sendable {
    case accepted(sent: Int, devices: Int, pruned: Int)
    case partial(sent: Int, devices: Int, pruned: Int)
    case noRegisteredDevices
    case retryableFailure
    case retryExhausted
    case authenticationRequired
    case authenticationUnavailable
    case staleSession
    case correlationConflict
    case expired
    case invalidResponse
    case rejected(statusCode: Int)
    case cancelled

    var shouldRetry: Bool {
        self == .retryableFailure || self == .authenticationUnavailable
    }

    static func decode(statusCode: Int, data: Data) -> Self {
        switch statusCode {
        case 200...299:
            guard let summary = try? JSONDecoder().decode(
                PhonePushServerSummary.self,
                from: data
            ), summary.sent >= 0, summary.devices >= 0,
            summary.pruned >= 0, summary.transientFailures >= 0,
            summary.permanentFailures >= 0,
            summary.sent <= summary.devices
            else { return .invalidResponse }
            if summary.devices == 0 { return .noRegisteredDevices }
            if summary.transientFailures > 0 { return .retryableFailure }
            if summary.sent == summary.devices,
               summary.permanentFailures == 0 {
                return .accepted(
                    sent: summary.sent,
                    devices: summary.devices,
                    pruned: summary.pruned
                )
            }
            if summary.sent > 0 {
                return .partial(
                    sent: summary.sent,
                    devices: summary.devices,
                    pruned: summary.pruned
                )
            }
            return .rejected(statusCode: statusCode)
        case 401, 403:
            return .authenticationRequired
        case 408, 425, 429, 500...599:
            return .retryableFailure
        case 409:
            let error = (try? JSONDecoder().decode(
                PhonePushErrorBody.self,
                from: data
            ))?.error
            if error == "push_event_in_progress" { return .retryableFailure }
            if error == "correlation_payload_mismatch" {
                return .correlationConflict
            }
            return .rejected(statusCode: statusCode)
        case 410:
            return .expired
        case 300...399:
            return .invalidResponse
        default:
            return .rejected(statusCode: statusCode)
        }
    }

    static func classifyTransportError(_ error: any Error) -> Self {
        guard let error = error as? URLError else { return .retryableFailure }
        return error.code == .cancelled ? .cancelled : .retryableFailure
    }

    static func retryAfterSeconds(
        response: HTTPURLResponse,
        data: Data
    ) -> Int? {
        let header = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Int.init)
        let summary = try? JSONDecoder().decode(
            PhonePushServerSummary.self,
            from: data
        ).retryAfterSeconds
        let error = try? JSONDecoder().decode(
            PhonePushErrorBody.self,
            from: data
        ).retryAfterSeconds
        guard let value = header ?? summary ?? error else { return nil }
        return max(value, 0)
    }
}

private struct PhonePushErrorBody: Decodable {
    let error: String?
    let retryAfterSeconds: Int?
}
