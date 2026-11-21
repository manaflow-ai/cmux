public import CmuxNextRemoteLocalhost
public import CmuxNextSettings
import CryptoKit
public import Foundation

/// A validated Cloud browser route shared by page, CLI and automatic recovery paths.
public nonisolated struct CloudBrowserRequest: Equatable, Sendable {
    /// Keeps Cloud store keys separate from daemon registry store keys.
    public static let machineKeyPrefix = "cmux.cloud.browser-store.v1:"

    /// Validated HTTP(S) loopback URL.
    public let url: URL
    /// Cloud machine identifier.
    public let machine: String
    /// Display name of the machine.
    public let machineName: String
    /// Server incarnation that owns the route.
    public let incarnation: UInt64
    /// Route generation within the incarnation.
    public let generation: UInt64
    /// Local authenticated HTTP proxy port.
    public let proxyPort: UInt16
    /// Credential bound to the route.
    public let credential: ProxyCredential

    /// Stable store key for a Cloud machine, independent of a route generation.
    ///
    /// - Parameter machine: The server-owned machine identifier.
    public static func machineKey(machine: String) -> String {
        SHA256.hash(data: Data((machineKeyPrefix + machine).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Validates a route the app requested directly, with the same checks as a page payload.
    ///
    /// - Parameters:
    ///   - route: The authenticated `cloud.browser.open` response.
    ///   - machineName: Display name used when opening the route.
    /// - Throws: A typed refusal for an invalid route.
    public static func route(_ route: JSONValue, machineName: String) throws(Refusal) -> Self {
        try checked(.object([
            "engine": .string("cef"), "url": route["url"] ?? .null,
            "incarnation": route["incarnation"] ?? .null, "generation": route["generation"] ?? .null,
            "machineStore": .object(["machine": route["machine"] ?? .null, "machineName": .string(machineName), "proxy": route["proxy"] ?? .null]),
        ]))
    }

    /// Validates proxy credentials, loopback destination and exact route version.
    ///
    /// The caller must separately authorize the payload's origin before opening it.
    /// - Parameter args: Browser action payload from an authorized caller.
    /// - Throws: A typed refusal for an invalid payload.
    public static func checked(_ args: JSONValue) throws(Refusal) -> Self {
        guard args["engine"]?.stringValue == "cef" else { throw .proxyRequiresCEF }
        guard let text = args["url"]?.stringValue, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              LoopbackHost(url: url)?.isLoopback == true else { throw .invalidURL }
        guard let store = args["machineStore"], let machine = store["machine"]?.stringValue, !machine.isEmpty,
              let proxy = store["proxy"], proxy["kind"]?.stringValue == "http", proxy["host"]?.stringValue == "127.0.0.1",
              case .number(let number)? = proxy["port"], number.rounded() == number, number >= 1, number <= 65535,
              let username = proxy["username"]?.stringValue, !username.isEmpty, username.utf8.count <= 128,
              let password = proxy["password"]?.stringValue, password.utf8.count >= 32, password.utf8.count <= 256,
              case .number(let incarnation)? = args["incarnation"], incarnation.rounded() == incarnation,
              incarnation >= 1, incarnation <= 9_007_199_254_740_991,
              case .number(let generation)? = args["generation"], generation.rounded() == generation,
              generation >= 1, generation <= 9_007_199_254_740_991
        else { throw .proxyInvalid }
        let name = store["machineName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? machine
        return Self(
            url: url,
            machine: machine,
            machineName: name,
            incarnation: UInt64(incarnation),
            generation: UInt64(generation),
            proxyPort: UInt16(number),
            credential: ProxyCredential(username: username, password: password)
        )
    }
}
