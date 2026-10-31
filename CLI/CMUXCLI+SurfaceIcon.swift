import Foundation
import CmuxControlSocket

extension CMUXCLI {
    static let surfaceIconUsage = String(localized: "cli.surface.icon.usage", defaultValue: """
    Usage: cmux surface icon set --workspace <UUID> --surface <UUID> --owner <ID> --pid <INT> --process-start <STR> [--asset-file <JSON>] [--lease-token <UUID>] [--revision <INT>] [--ttl <5..120>]
           cmux surface icon clear --workspace <UUID> --surface <UUID> --owner <ID> --lease-token <UUID> --revision <INT>
    Asset JSON: {"frames":[{"svg":"<svg/>","duration_ms":100}],"loop":true,"static_frame":0}
    Omit --asset-file only to renew an existing lease. Targets must be UUIDs; focus and handle fallback are not supported.
    """,
    bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
    )

    func runSurfaceIconCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let request = try Self.surfaceIconRequest(commandArgs)
        let payload = try client.sendV2(method: request.method, params: request.params)
        // Lease tokens and revisions are load-bearing for subsequent renewal/clear;
        // preserve the complete response rather than reducing it to an OK message.
        print(jsonString(payload))
    }

    /// Pure argument validation and bounded asset loading, before connecting to the socket.
    static func surfaceIconRequest(_ args: [String]) throws -> (method: String, params: [String: Any]) {
        guard let operation = args.first, ["set", "clear"].contains(operation) else {
            throw CLIError(message: surfaceIconUsage)
        }
        let clear = operation == "clear"
        let allowed: Set<String> = clear
            ? ["--workspace", "--surface", "--owner", "--lease-token", "--revision"]
            : ["--workspace", "--surface", "--owner", "--pid", "--process-start", "--asset-file", "--lease-token", "--revision", "--ttl"]
        var options: [String: String] = [:]
        var index = 1
        while index < args.count {
            let key = args[index]
            guard allowed.contains(key), options[key] == nil, index + 1 < args.count,
                  !args[index + 1].hasPrefix("--") else { throw surfaceIconInvalid(key) }
            options[key] = args[index + 1]
            index += 2
        }
        func uuid(_ key: String) throws -> String {
            guard let raw = options[key], raw.utf8.count == 36,
                  let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw.lowercased() else {
                throw surfaceIconInvalid(key)
            }
            return uuid.uuidString
        }
        func text(_ key: String, limit: Int) throws -> String {
            guard let raw = options[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  raw.utf8.count <= limit else { throw surfaceIconInvalid(key) }
            return raw
        }
        func integer(_ key: String, range: ClosedRange<Int>) throws -> Int {
            guard let raw = options[key], let number = Int(raw), range.contains(number) else {
                throw surfaceIconInvalid(key)
            }
            return number
        }
        var params: [String: Any] = [
            "workspace_id": try uuid("--workspace"),
            "surface_id": try uuid("--surface"),
            "owner_id": try text("--owner", limit: 200),
        ]
        if clear || options["--lease-token"] != nil { params["lease_token"] = try uuid("--lease-token") }
        if clear || options["--revision"] != nil { params["expected_revision"] = try integer("--revision", range: 1...Int.max) }
        if !clear {
            params["expected_agent_pid"] = try integer("--pid", range: 1...Int.max)
            params["expected_process_start"] = try text("--process-start", limit: 80)
            if options["--ttl"] != nil { params["ttl_seconds"] = try integer("--ttl", range: 5...120) }
            if let path = options["--asset-file"] {
                // A bounded read also caps escaped JSON overhead, not just decoded SVG bytes.
                let url = URL(fileURLWithPath: path)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw surfaceIconInvalid("--asset-file")
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 4 * 1024 * 1024,
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let json = JSONValue(foundationObject: object),
                      surfaceIconAssetIsValid(json) else { throw surfaceIconInvalid("--asset-file") }
                params["asset"] = object
            } else if options["--lease-token"] == nil {
                throw surfaceIconInvalid("--asset-file")
            }
        }
        return ("surface.icon.\(operation)", params)
    }

    private static func surfaceIconInvalid(_ option: String) -> CLIError {
        CLIError(message: String(format: String(
            localized: "cli.surface.icon.invalidOption", defaultValue: "surface icon: invalid or missing option %@",
            bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        ), option))
    }

    private static func surfaceIconAssetIsValid(_ value: JSONValue) -> Bool {
        guard case .object(let asset) = value,
              Set(asset.keys).isSubset(of: ["frames", "loop", "static_frame"]),
              case .bool = asset["loop"], case .array(let frames) = asset["frames"],
              (1...64).contains(frames.count) else { return false }
        func integer(_ value: JSONValue?) -> Int? {
            switch value {
            case .int(let number): return Int(exactly: number)
            case .double(let number): return Int(exactly: number)
            default: return nil
            }
        }
        if let raw = asset["static_frame"] {
            guard let index = integer(raw), frames.indices.contains(index) else { return false }
        }
        var bytes = 0
        var milliseconds = 0
        for value in frames {
            guard case .object(let frame) = value,
                  Set(frame.keys) == ["svg", "duration_ms"],
                  case .string(let svg) = frame["svg"],
                  !svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  svg.utf8.count <= 16 * 1024,
                  let duration = integer(frame["duration_ms"]), (50...5000).contains(duration) else { return false }
            bytes += svg.utf8.count
            milliseconds += duration
        }
        return bytes <= 512 * 1024 && milliseconds <= 30_000
    }
}
