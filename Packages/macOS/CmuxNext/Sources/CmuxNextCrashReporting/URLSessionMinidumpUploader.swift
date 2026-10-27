public import Foundation
import CmuxNextCompat

/// Posts to Sentry's minidump endpoint of a DSN (`/api/<project>/minidump/?sentry_key=<key>`, the endpoint
/// Crashpad itself would upload to) with an ephemeral session: no cookies, cache or credentials, fixed headers,
/// 60 s timeout, no redirects (a per-task delegate). Completions run on the session's own delegate queue. The
/// session is made at the first upload, so a launch with nothing to send makes none.
public nonisolated final class URLSessionMinidumpUploader: MinidumpUploading {
    /// Where dumps go; nil (a DSN that does not parse) sends nothing.
    public let endpoint: URL?
    private let session = Mutex<URLSession?>(nil)

    public init(dsn: String) {
        endpoint = Self.endpoint(dsn: dsn)
    }

    /// The upload session, made once.
    private func uploadSession() -> URLSession {
        session.withLock { made in
            if let made { return made }
            let new = Self.makeSession()
            made = new
            return new
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "cmux-minidumps/1", "Accept-Language": "en", "Accept": "*/*"]
        return URLSession(configuration: configuration)
    }

    /// `https://<key>@<host>/<project>` as `https://<host>/api/<project>/minidump/?sentry_key=<key>`.
    static func endpoint(dsn: String) -> URL? {
        guard let parsed = URLComponents(string: dsn), parsed.scheme == "https", let host = parsed.host,
              let key = parsed.user, !key.isEmpty else { return nil }
        let project = parsed.path.split(separator: "/").last.map(String.init) ?? ""
        guard !project.isEmpty, project.allSatisfy(\.isNumber) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = parsed.port
        components.path = "/api/\(project)/minidump/"
        components.queryItems = [URLQueryItem(name: "sentry_key", value: key)]
        return components.url
    }

    public func upload(_ request: MinidumpUploadRequest, completion: @escaping @Sendable (MinidumpUploadOutcome) -> Void) {
        guard let endpoint else { return completion(.refused(status: 0)) }
        let boundary = "cmux-minidump-\(UUID().uuidString)"
        var post = URLRequest(url: endpoint)
        post.httpMethod = "POST"
        post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let task = uploadSession().uploadTask(with: post, from: request.multipartBody(boundary: boundary)) { _, response, _ in
            guard let http = response as? HTTPURLResponse else { return completion(.retryLater) }
            completion(.of(status: http.statusCode))
        }
        task.delegate = MinidumpUploadNoRedirects()
        task.resume()
    }
}

/// Refuses every redirect, so the 3xx answer itself comes back and the dump never goes to another address.
private final class MinidumpUploadNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
