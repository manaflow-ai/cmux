public import Foundation

/// `cloud new-machine --repo OWNER/NAME[@REF]` (or any https git URL): the repository the new machine
/// clones into `~/work/NAME` before its bootstrap script runs. The forms, the checks, `repo.json` and
/// the `repo` step are Rust's (cmux-cloud-start-core's `machine_repo`, with their tests), asked over
/// the app FFI (`cloud_machine_repo_*`). The step writes no token; it uses the GitHub or host access
/// the machine already has and resets every other helper.
public struct CloudMachineRepo: Equatable, Sendable, Encodable {
    public static let gitHub = "github.com"

    /// On GitHub, the owner; elsewhere the group path (`group/subgroup` on GitLab).
    public var owner: String
    public var name: String
    /// A branch, tag or commit; nil keeps the remote's default branch.
    public var ref: String?
    /// The git host, lowercased: `github.com`, or the host of an https URL.
    public var host: String

    public init(owner: String, name: String, ref: String? = nil, host: String = Self.gitHub) {
        self.owner = owner
        self.name = name
        self.ref = ref
        self.host = host
    }

    public var isGitHub: Bool { host == Self.gitHub }

    public enum Invalid: String, Error, Equatable, Decodable {
        /// Not a GitHub repository or an https git URL in one of the accepted forms.
        case unrecognized
        /// A token or password in the URL: it would land in the machine's git config.
        case credentialsInURL
        case invalidRef
    }

    /// Everything Rust says of a repository: its URL, folder, spec, `repo.json` and step.
    struct Description: Decodable {
        var owner: String, name: String, ref: String?, host: String
        var url: String, directory: String, spec: String, record: String, step: String
        var repo: CloudMachineRepo { CloudMachineRepo(owner: owner, name: name, ref: ref, host: host) }
    }

    var facts: Description? { CloudStartCore().call("cloud_machine_repo_describe", self, as: Description.self) }

    public var url: String { facts?.url ?? "https://\(host)/\(owner)/\(name).git" }
    /// Relative to the machine user's home.
    public var directory: String { facts?.directory ?? "work/\(name)" }
    public var spec: String {
        facts?.spec ?? (isGitHub ? "\(owner)/\(name)" : "https://\(host)/\(owner)/\(name)") + (ref.map { "@\($0)" } ?? "")
    }
    /// `repo.json`: what the machine was asked to clone, for a person or a tool reading the machine.
    public var record: Data { Data((facts?.record ?? "").utf8) }
    /// The `repo` step (`~/.cmux/bootstrap/repo`); empty when the app's rules do not answer.
    public var step: String { facts?.step ?? "" }

    /// `owner/name`, a GitHub https, scp or ssh URL, or another host's https URL, each with an
    /// optional `@REF`; Rust says which repository it names or why it names none.
    public static func parse(_ raw: String) throws -> CloudMachineRepo {
        struct Request: Encodable { var spec: String }
        struct Reply: Decodable { var repo: Description?, invalid: Invalid? }
        guard let reply = CloudStartCore().call("cloud_machine_repo_parse", Request(spec: raw), as: Reply.self) else { throw Invalid.unrecognized }
        if let repo = reply.repo { return repo.repo }
        throw reply.invalid ?? .unrecognized
    }

    /// A branch, tag or commit name the step can use without quoting.
    static func isRef(_ value: String) -> Bool {
        struct Request: Encodable { var ref: String }
        struct Reply: Decodable { var isRef: Bool }
        return CloudStartCore().call("cloud_machine_repo_is_ref", Request(ref: value), as: Reply.self)?.isRef ?? false
    }
}
