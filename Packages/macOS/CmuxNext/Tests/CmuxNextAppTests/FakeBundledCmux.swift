import CmuxNextCloud
import CmuxNextWakeups
import Foundation

/// A stand-in bundled `cmux` for the Cloud API clients' tests: each run saves its stdin
/// (`stdin.N`) and argv (`argv.N`), then prints `answer.N` (or `answer` when there is none) as its
/// one line. The requests' HTTP is cmux-tui's and is tested there (`cli/cloud_api/tests.rs`); these
/// tests check what the app hands it and how the app reads the answer.
nonisolated struct FakeBundledCmux {
    let folder: URL
    let cli: BundledCmux

    init(answer: String = #"{"ok":true,"body":null}"#) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-cmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("cmux")
        let dir = folder.path
        let script = """
            #!/bin/sh
            n=$(( $(cat "\(dir)/count" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "\(dir)/count"
            cat > "\(dir)/stdin.$n"
            echo "$@" > "\(dir)/argv.$n"
            if [ -f "\(dir)/answer.$n" ]; then cat "\(dir)/answer.$n"; else cat "\(dir)/answer"; fi
            echo

            """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        cli = BundledCmux(binary: binary, work: BackgroundWork())
        try answer(answer)
    }

    /// Every run prints `line` (unless an `answer.N` says otherwise).
    func answer(_ line: String) throws { try Data(line.utf8).write(to: folder.appendingPathComponent("answer")) }

    /// Run `n` (from 1) prints `line`.
    func answer(_ n: Int, _ line: String) throws { try Data(line.utf8).write(to: folder.appendingPathComponent("answer.\(n)")) }

    /// How many runs there were.
    var runs: Int { Int(((try? String(contentsOf: folder.appendingPathComponent("count"), encoding: .utf8)) ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }

    /// Run `n`'s stdin, its first line read as the request.
    func request(_ n: Int) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("stdin.\(n)")) else { return [:] }
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    }

    /// Run `n`'s raw stdin.
    func stdin(_ n: Int) -> Data { (try? Data(contentsOf: folder.appendingPathComponent("stdin.\(n)"))) ?? Data() }

    /// Run `n`'s argv, as `echo` printed it.
    func argv(_ n: Int) -> String {
        ((try? String(contentsOf: folder.appendingPathComponent("argv.\(n)"), encoding: .utf8)) ?? "").trimmingCharacters(in: .newlines)
    }

    /// Every request's `call` (and `args.op` for `machine.io`), in order.
    var calls: [String] {
        (0..<runs).map { index in
            let request = request(index + 1)
            let call = request["call"] as? String ?? ""
            let op = (request["args"] as? [String: Any])?["op"] as? String
            return op.map { "\(call) \($0)" } ?? call
        }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    static let configuration = CloudConfiguration.resolve(
        bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"], process: [:], isDebugBuild: true)

    /// Classic cmux.com's client over this cmux.
    func classic(team: String? = "team-1", tokens: @escaping CloudAPIClient.Tokens = { ("access", "refresh") }) -> CloudAPIClient {
        CloudAPIClient(configuration: Self.configuration, tokens: tokens, teamID: { team }, cli: cli)
    }

    /// A Worker machines client over this cmux.
    func worker(team: String? = "team_cmux") -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? folder, accessToken: { "session-access" },
                                      teamID: { team }, cli: cli, sessions: folder.appendingPathComponent("sessions"))
    }

    /// The person's owner client over this cmux.
    func owner(team: String? = "team_cmux") -> CloudOwnerAPIClient {
        CloudOwnerAPIClient(baseURL: URL(string: "https://api.standin.invalid") ?? folder, accessToken: { "session-access" },
                            teamID: { team }, cli: cli)
    }
}
