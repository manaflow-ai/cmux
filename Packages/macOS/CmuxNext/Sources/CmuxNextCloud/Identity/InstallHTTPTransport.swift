public import CMUXAuthCore
public import CmuxInstallAuthCore
public import Foundation

/// POSTs install-auth JSON to the API Worker at `baseURL` through the bundled cmux's `cmux cloud install-post`
/// (cmux-tui `cli/cloud_install_post.rs`), which sends it: redirects refused, nothing cached, a read hedged and a
/// keyed op resent on a new socket. The request (its bearer too) goes on the child's stdin, never in argv.
public struct InstallHTTPTransport: InstallAuthTransport {
    private let baseURL: URL
    /// A tagged dev build's cloud data space (``CloudConfiguration/buildSpace``); a misconfigured dev build's requests throw.
    private let buildSpace: CMUXBuildSpaceState
    /// The bundled cmux; nil (no cmux in this build): every request throws.
    private let machineIO: CloudMachineIO?

    public init(baseURL: URL, buildSpace: CMUXBuildSpaceState, machineIO: CloudMachineIO?) {
        self.baseURL = baseURL
        self.buildSpace = buildSpace
        self.machineIO = machineIO
    }

    public func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let reply = try await send(path, json: json, bearer: bearer, headers: headers)
        return (reply.status, reply.body)
    }

    /// ``post(_:json:bearer:headers:)`` where one attempt waits `attempt` seconds (a create waits for the provider);
    /// `resent` is whether a second attempt started, so the first may have reached the server.
    public func send(_ path: String, json: Data, bearer: String?, headers: [String: String], attempt: Int = 15) async throws -> (status: Int, body: Data, resent: Bool) {
        try buildSpace.check()
        guard let machineIO else { throw URLError(.cannotConnectToHost) }
        var request: [String: Any] = ["api": baseURL.absoluteString, "path": path, "body": String(decoding: json, as: UTF8.self), "headers": headers, "timeout_secs": attempt]
        if let bearer { request["bearer"] = bearer }
        let output: Data
        do {
            output = try await CloudMachineIO.run(machineIO.binary, arguments: ["cloud", "install-post"],
                                                  stdin: try JSONSerialization.data(withJSONObject: request), timeout: .seconds(attempt * 2 + 10), work: machineIO.work)
        } catch let noAnswer as CloudMachineIO.NoAnswer {
            throw URLError(noAnswer.dispatched ? .timedOut : .cannotConnectToHost)
        }
        struct Answer: Decodable { var ok: Bool; var status: Int?; var body: String?; var error: [String: String]?; var resent: Bool? }
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }),
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(line)) else { throw URLError(.badServerResponse) }
        guard answer.ok, let status = answer.status else { throw URLError(answer.error?["kind"] == "timeout" ? .timedOut : .cannotConnectToHost) }
        return (status, Data((answer.body ?? "").utf8), answer.resent == true)
    }
}
