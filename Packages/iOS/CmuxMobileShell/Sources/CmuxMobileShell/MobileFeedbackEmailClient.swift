public import CmuxMobileShellModel
public import Foundation

/// Default ``MobileFeedbackEmailSubmitting`` that POSTs to the cmux web
/// `/api/feedback` route (the same multipart endpoint the macOS feedback
/// composer uses), which emails the feedback inbox via Resend.
///
/// The build/device stamp is carried as form fields (`appVersion`, `appBuild`,
/// `bundleIdentifier`, `osVersion`, `hardwareModel`, and `buildType`) so the
/// server subject and body identify which build the report came from. No
/// diagnostic blob or terminal text is sent on this path; it carries only the
/// freeform message and the stamp.
public struct MobileFeedbackEmailClient: MobileFeedbackEmailSubmitting {
    private let endpoint: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL with no trailing slash (e.g.
    ///     `https://cmux.dev`). `/api/feedback` is appended.
    ///   - session: The URLSession used for the POST.
    ///   - requestTimeout: Per-request deadline.
    public init?(
        apiBaseURL: String,
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        let trimmed = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: trimmed + "/api/feedback") else { return nil }
        self.endpoint = url
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// POST the feedback message + stamp to `/api/feedback` as multipart form
    /// data.
    ///
    /// - Parameters:
    ///   - email: The reply-to address.
    ///   - message: The freeform feedback body.
    ///   - stamp: The build + device stamp carried as form fields.
    /// - Throws: ``MobileFeedbackEmailError`` on a transport or non-2xx error.
    public func submit(email: String, message: String, stamp: MobileFeedbackStamp) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.multipartBody(
            email: email,
            message: message,
            stamp: stamp,
            boundary: boundary
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MobileFeedbackEmailError.transport
        }
        _ = data
        guard let http = response as? HTTPURLResponse else {
            throw MobileFeedbackEmailError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobileFeedbackEmailError.rejected(statusCode: http.statusCode)
        }
    }

    /// Build the multipart/form-data body for the feedback POST.
    ///
    /// Pure and `static` so the field shape (names + stamp mapping) is unit
    /// testable without a network. Mirrors the macOS composer's field names so
    /// the same web route handles both surfaces; `buildType` and `locale` are
    /// the mobile additions.
    static func multipartBody(
        email: String,
        message: String,
        stamp: MobileFeedbackStamp,
        boundary: String
    ) -> Data {
        var body = Data()
        appendField("email", email, to: &body, boundary: boundary)
        appendField("message", message, to: &body, boundary: boundary)
        appendField("appVersion", stamp.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", stamp.appBuild, to: &body, boundary: boundary)
        appendField("bundleIdentifier", stamp.bundleIdentifier, to: &body, boundary: boundary)
        appendField("buildType", stamp.buildType.token, to: &body, boundary: boundary)
        appendField("osVersion", stamp.osVersion, to: &body, boundary: boundary)
        appendField("hardwareModel", stamp.deviceModel, to: &body, boundary: boundary)
        appendField("locale", Locale.preferredLanguages.first ?? Locale.current.identifier, to: &body, boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func appendField(
        _ name: String,
        _ value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }
}
