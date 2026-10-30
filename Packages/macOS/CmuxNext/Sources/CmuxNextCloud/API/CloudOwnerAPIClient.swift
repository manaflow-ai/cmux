public import Foundation

/// The cmux-next API Worker's routes that a person's own session calls directly, outside the op
/// path (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
/// machine of the app server link (`POST /v1/cloud/machines/{machine}/acpmux/...`), and the reads of
/// the person's hand-offs (`GET /v1/handoffs...`, CloudHandoffs.swift).
///
/// The person key never goes through `apps-run`, the local daemon or a Cloud op (those record
/// their params). Every header this client sets is `Authorization` (the Stack session, which the
/// Worker's logs mask), `Content-Type`, `Content-Length` and `x-cmux-team`; URLSession adds
/// `User-Agent`, `Accept`, `Accept-Language`, `Accept-Encoding` and `Host`, none of which holds a
/// credential. The Worker's invocation logs (on in development) record the URL and every header
/// but Authorization, so nothing outside the body may hold a key. No cache, no cookies, no
/// redirect is followed, and nothing is retried.
public struct CloudOwnerAPIClient: Sendable {
    public typealias AccessToken = @Sendable () async throws -> String
    /// The cmux team (`team_…`) whose machine this is: the install token's team claim.
    public typealias TeamID = @Sendable () async -> String?

    public let baseURL: URL
    let accessToken: AccessToken
    let teamID: TeamID
    let session: URLSession

    public init(baseURL: URL, accessToken: @escaping AccessToken, teamID: @escaping TeamID) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.teamID = teamID
        session = Self.transport
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
    /// this app's person key. `writeKey` writes the key line (`keyLineLength` bytes) into the body
    /// stream from the caller's own zeroed buffer, as ``CloudAPIClient/acpmuxKeyedStart(_:keyLineLength:writeKey:)``
    /// does: no `Data` or `String` copy here, and a stream body is never resent. Answers the new
    /// daemon run (`personInstance`).
    public func acpmuxKeyedStart(_ machine: String, keyLineLength: Int, writeKey: (OutputStream) -> Bool) async throws -> String {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: keyLineLength * 2, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CloudAPIError.transport("no request body stream") }
        output.open()
        let wrote = writeKey(output)
        output.close()
        guard wrote else { throw CloudAPIError.transport("the key did not reach the request body") }
        struct Started: Decodable { var personInstance: String }
        return try await post(machine, "keyed-start", body: .stream(input, keyLineLength, "application/octet-stream"),
                              timeout: .seconds(100), as: Started.self).personInstance
    }

    /// `POST /v1/cloud/machines/{machine}/acpmux/person-holds {nonce}`: what the machine's acpmux
    /// answers to `_acpmux/person_holds`. The caller checks the proof against its own key.
    public func acpmuxPersonHolds(_ machine: String, nonce: String) async throws -> (instance: String, proof: String) {
        struct Holds: Decodable { var instance: String; var proof: String }
        let data = try JSONSerialization.data(withJSONObject: ["nonce": nonce])
        let holds = try await post(machine, "person-holds", body: .data(data, "application/json"), timeout: .seconds(40), as: Holds.self)
        return (holds.instance, holds.proof)
    }

    enum Body {
        case stream(InputStream, Int, String)
        case data(Data, String)
    }

    func post<T: Decodable>(_ machine: String, _ action: String, body: Body, timeout: Duration, as type: T.Type) async throws -> T {
        // The machine id is the only path part that varies; anything else is refused before a request.
        guard machine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.transport("not a Cloud machine id")
        }
        let path = "/v1/cloud/machines/\(machine)/acpmux/\(action)"
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = "POST"
        // RULE (cx-kvmz, hq-84): this client sets only these four headers: Authorization (the
        // Worker's invocation log masks it), Content-Type, Content-Length and x-cmux-team. The log
        // records every other header and the URL, so no other header, no query and no path part
        // that could hold a key may ever be added here.
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        switch body {
        case let .stream(stream, length, contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            request.httpBodyStream = stream
        case let .data(data, contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        let data: Data
        let response: URLResponse
        do {
            let session = session, prepared = request
            (data, response) = try await withDeadline(timeout, label: "POST \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        // The Worker's shape: {ok: true, value} or {ok: false, error: {code, message}}.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), object?["ok"] as? Bool == true, let value = object?["value"] else {
            let error = object?["error"] as? [String: Any]
            throw CloudAPIError.http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        do {
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
        } catch {
            throw CloudAPIError.decoding("\(path): \(error)")
        }
    }

    /// `GET path?name=value…` with integer query values and a list cursor (base64url) only: answers the 2xx
    /// body as sent. Any other answer throws ``CloudAPIError/http(status:code:message:action:traceId:)``
    /// with the route's `{error: {code, message}}`.
    func get(_ path: String, query: [(String, Int)], cursor: String? = nil, timeout: Duration) async throws -> Data {
        if let cursor, cursor.range(of: #"^[A-Za-z0-9_-]{1,512}$"#, options: .regularExpression) == nil {
            throw CloudAPIError.transport("not a list cursor")
        }
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        let pairs = (query.map { "\($0.0)=\($0.1)" } + (cursor.map { ["cursor=\($0)"] } ?? [])).joined(separator: "&")
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path + (pairs.isEmpty ? "" : "?" + pairs)) else { throw CloudAPIError.transport("bad path \(path)") }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout.components.seconds))
        request.httpMethod = "GET"
        // RULE (cx-kvmz, hq-84), as in post(_:_:body:timeout:as:): Authorization and x-cmux-team
        // only; the path's one varying part is a checked id and the query holds integers and the
        // store's own list cursor alone.
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let team = await teamID() { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        let data: Data
        let response: URLResponse
        do {
            let session = session, prepared = request
            (data, response) = try await withDeadline(timeout, label: "GET \(path)") { try await session.data(for: prepared) }
        } catch is DeadlineExceeded {
            throw CloudAPIError.timedOut(path)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            throw CloudAPIError.http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        return data
    }

    /// No cache, no cookies, and redirects refused: the Stack bearer never follows one.
    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
