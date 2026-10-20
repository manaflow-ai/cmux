import CmuxNextDaemon
public import Foundation

/// One read of `cmux host list --json --all`: the hosts that answered, and the other
/// eligible peers with why (plans/cmux-next/remote-hosts.md 9).
public struct RemoteHostList: Equatable, Sendable {
    public var hosts: [String]
    /// Name to reason (`offline`, `not serving`, `no answer`, `not_allowed`, `session_down`, ...).
    public var unavailable: [String: String]

    public init(hosts: [String], unavailable: [String: String]) {
        self.hosts = hosts
        self.unavailable = unavailable
    }

    /// `cmux host list --json --all` through `cli`: the hosts that answered the probe and the
    /// other eligible peers with why (offline ones included), except this machine; nil when the
    /// CLI is missing, fails (the private network is off) or prints something else.
    public nonisolated static func read(cli: URL?) async -> RemoteHostList? {
        guard let cli,
              let result = try? await ProcessRunner.run(executable: cli, arguments: ["host", "list", "--json", "--all"], environment: nil,
                                                        timeout: .seconds(15), clock: ContinuousClock()),
              result.status == 0 else { return nil }
        return parse(result.stdout)
    }

    /// A `cmux host list --json --all` reply
    /// (`{"hosts":[{"name",…}],"not_hosts":[{"name","reason"}],"self":…}`); nil when the reply
    /// has no `hosts` array.
    public nonisolated static func parse(_ data: Data) -> RemoteHostList? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hosts = object["hosts"] as? [Any] else { return nil }
        let me = (object["self"] as? String)?.lowercased()
        let keep = { (name: String) in !name.isEmpty && name.lowercased() != me }
        var unavailable: [String: String] = [:]
        for case let entry as [String: Any] in object["not_hosts"] as? [Any] ?? [] {
            guard let name = entry["name"] as? String, keep(name) else { continue }
            unavailable[name] = entry["reason"] as? String ?? "unreachable"
        }
        return RemoteHostList(hosts: hosts.compactMap { ($0 as? [String: Any])?["name"] as? String }.filter(keep),
                              unavailable: unavailable)
    }

    /// `Contents/Resources/bin/cmux` of the running app, when it is there and executable.
    public static func bundledCLI() -> URL? {
        let bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
}
