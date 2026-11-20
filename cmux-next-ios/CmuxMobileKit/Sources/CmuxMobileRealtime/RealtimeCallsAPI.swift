import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "chief-call")

/// Performs one HTTP request (URLSession in the app, a fake in tests).
public protocol VoiceCallHTTP: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession as ``VoiceCallHTTP``.
public struct URLSessionVoiceCallHTTP: VoiceCallHTTP {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a Chief call could not start or ended early.
public enum VoiceCallFailure: Error, Sendable, Equatable {
    case microphoneDenied
    case keyMissing
    /// OpenAI refused the key (401).
    case keyRejected
    /// The key's project can't use the model (403/404).
    case modelUnavailable(String)
    /// Out of credit or over the rate limit (429).
    case quota(String)
    /// The request reached OpenAI and was refused for another reason.
    case refused(String)
    /// OpenAI failed on its side (5xx), often with no error body; the call
    /// retries once before showing it. `requestID` traces it with OpenAI.
    case server(status: Int, requestID: String?)
    /// No network, TLS failure, or the audio connection could not be set up.
    case network(String)
    /// The connection dropped during the call.
    case dropped
}

/// `POST /v1/realtime/calls`: the phone's WebRTC offer and the session
/// config go to OpenAI with the user's key; the answer SDP comes back. The
/// key leaves the phone only in this request's Authorization header.
public struct RealtimeCallsAPI: Sendable {
    public static let defaultBase = URL(string: "https://api.openai.com/v1")!
    let base: URL
    let http: any VoiceCallHTTP

    public init(base: URL = RealtimeCallsAPI.defaultBase, http: any VoiceCallHTTP = URLSessionVoiceCallHTTP()) {
        self.base = base
        self.http = http
    }

    /// Exchanges the offer for OpenAI's answer.
    /// - Parameters:
    ///   - offerSDP: The phone's offer (an audio track and the `oai-events` data channel).
    ///   - session: ``VoiceCallSessionConfig/json``.
    ///   - apiKey: The user's key.
    ///   - safetyIdentifier: A hash of the cmux account (OpenAI's abuse signals; never the account id itself).
    /// - Returns: The answer SDP.
    public func connect(offerSDP: String, session: Data, apiKey: String, safetyIdentifier: String?) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("realtime/calls"))
        request.httpMethod = "POST"
        let boundary = "cmux-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let safetyIdentifier { request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier") }
        request.httpBody = Self.multipart(boundary: boundary, fields: [
            ("sdp", "application/sdp", Data(offerSDP.utf8)),
            ("session", "application/json", session),
        ])
        request.timeoutInterval = 20
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.perform(request)
        } catch {
            throw VoiceCallFailure.network(error.localizedDescription)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let failure = Self.failure(status: response.statusCode, body: data,
                                       requestID: response.value(forHTTPHeaderField: "x-request-id"))
            log.error("realtime/calls HTTP \(response.statusCode, privacy: .public) request \(response.value(forHTTPHeaderField: "x-request-id") ?? "-", privacy: .public)")
            throw failure
        }
        let answer = String(decoding: data, as: UTF8.self)
        guard answer.hasPrefix("v=") else { throw VoiceCallFailure.refused("OpenAI sent no audio answer.") }
        return answer
    }

    static func multipart(boundary: String, fields: [(name: String, type: String, body: Data)]) -> Data {
        var data = Data()
        for field in fields {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\nContent-Type: \(field.type)\r\n\r\n".utf8))
            data.append(field.body)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// Maps an OpenAI error response (`{"error": {"message", "code", "type"}}`).
    static func failure(status: Int, body: Data, requestID: String? = nil) -> VoiceCallFailure {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let code = error?["code"] as? String
        switch status {
        case 401: return .keyRejected
        case 403, 404: return .modelUnavailable(message)
        case 429: return .quota(code == "insufficient_quota" ? String(localized: "Your OpenAI account is out of credit.") : message)
        case 500 ..< 600: return .server(status: status, requestID: requestID)
        default: return .refused(message)
        }
    }
}

/// Checks a key with `GET /v1/models/<model>`: free, and it proves the key
/// can see the voice model.
public struct OpenAIKeyVerifier: Sendable {
    let base: URL
    let http: any VoiceCallHTTP

    public init(base: URL = RealtimeCallsAPI.defaultBase, http: any VoiceCallHTTP = URLSessionVoiceCallHTTP()) {
        self.base = base
        self.http = http
    }

    public func check(key: String, model: String) async -> OpenAIKeyCheck {
        var request = URLRequest(url: base.appendingPathComponent("models").appendingPathComponent(model))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await http.perform(request)
            switch response.statusCode {
            case 200 ..< 300: return .valid
            case 401: return .rejected
            case 403, 404: return .modelUnavailable
            case 429: return .quota
            default: return .unreachable(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
