public import CmuxInstallAuthCore
public import Foundation

/// POSTs JSON to the API Worker. Redirects are refused: a bearer or a
/// signature never follows a 3xx to another origin.
public final class URLSessionInstallAuthTransport: InstallAuthTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" }))))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = json
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // The completion-handler form, not the async one: Xcode 26.6's
            // compiler crashes emitting the ObjC thunk for the async variant.
            completionHandler(nil)
        }
    }
}
