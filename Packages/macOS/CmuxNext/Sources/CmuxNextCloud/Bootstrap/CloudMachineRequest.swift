import CmuxNextCompat
public import CmuxNextWakeups
import Darwin
public import Foundation

/// What `cloud new-machine` asked for beyond the plan's default machine, in one call:
/// `cmux cloud new-machine --persistent --size medium --name lane-vm-1 --bootstrap lane
/// --bootstrap-script tools/lane-vm-bootstrap` (leo-workspace machines/lane-vms.md). A bare
/// New Cloud Machine (palette, menu, a plain CLI run) is ``isDefault`` and takes the old path.
public struct CloudMachineRequest: Equatable, Sendable {
    public var name: String?
    /// The size's name (`medium`) and its memory, which the create sends (`memoryMb`); the
    /// server's size ladder picks the vCPUs from it.
    public var size: String?
    public var memoryMb: Int?
    /// The machine's idle auto-pause is Off from its create (`idlePauseMinutes` 0).
    public var persistent = false
    /// `--bootstrap-script FILE` (absolute: the CLI resolved it against its working directory).
    public var bootstrapPath: String?
    public var bootstrapKind: CloudMachineBootstrap.Kind = .plain
    /// `--machine-config FILE` (``CloudMachineConfig``), absolute like ``bootstrapPath``.
    public var machineConfigPath: String?
    /// `--repo OWNER/NAME[@REF]`, cloned before the script (or alone).
    public var repo: CloudMachineRepo?
    /// The chat's pick (``CloudWorkPick/autosize``): the server sizes the machine for the task
    /// unless ``memoryMb`` names a size. Not a request option of its own (``isDefault``): a bare
    /// create from a chat still takes the plain path, sized for that chat.
    public var autosize: CloudAutosizeRequest?
    /// One key per request: the creation's Retry sends it again, so a create that reached the
    /// server but whose answer was lost does not make a second machine.
    public var idempotencyKey = UUID().uuidString
    /// The create was sent at least once with ``idempotencyKey``.
    public var wasSent = false
    /// The team the first send went to (`X-Cmux-Team-Id`): the key is scoped per team, so every
    /// retry, and the bootstrap and idle-pause calls on the machine, go to this team.
    public var team: String?
    /// The approval request this create's key was answered with: a Retry while the approved create
    /// still runs waits for it instead of answering a request that is already closed.
    public var approvedRequest: String?
    /// The approval request an attempt with this key began answering (set before the answer goes out):
    /// a Retry after that attempt was cancelled mid-answer may find the request running, its feed item
    /// closed, and waits for it like an answered one.
    public var answeringRequest: String?
    /// The loaded bootstrap (``loadScript(work:)``), started by the create itself once the machine
    /// exists, so the creation's Retry starts it too.
    public var script: CloudMachineBootstrap?
    /// The loaded `--machine-config` (``loadMachineConfig(work:)``), applied by the create after the bootstrap starts.
    public var machineConfig: CloudMachineConfig?
    /// A Cloud environment (`env_…`) to boot the machine in (`cloud.environment.boot`, cmux-next
    /// Cloud only): from its snapshot when it is built, otherwise from the image with its setup started
    /// on the machine. Not an option of the machine itself, so ``isDefault`` ignores it.
    public var environment: String?
    /// The Chief the machine is made for (a Chief's New Cloud Computer…): an unnamed machine takes its
    /// computer's name, "Ada’s Computer". It only names the machine, so ``isDefault`` ignores it.
    public var namedFor: String?

    /// A machine name `cloud new-machine` takes: 1-64 of letters, digits, `.`, `_` and `-`, not
    /// starting with `-`, so it is also a host name and a shell word in the commands it prints.
    /// `true` is what a bare `--name` with no value becomes on its way to the app.
    public static func isPlainName(_ name: String) -> Bool {
        name != "true" && (1...64).contains(name.count) && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    public init(name: String? = nil, size: String? = nil, memoryMb: Int? = nil, persistent: Bool = false,
                bootstrapPath: String? = nil, bootstrapKind: CloudMachineBootstrap.Kind = .plain, repo: CloudMachineRepo? = nil) {
        self.name = name
        self.size = size
        self.memoryMb = memoryMb
        self.persistent = persistent
        self.bootstrapPath = bootstrapPath
        self.bootstrapKind = bootstrapKind
        self.repo = repo
    }

    public var isDefault: Bool { name == nil && size == nil && !persistent && bootstrapPath == nil && machineConfigPath == nil && repo == nil }

    /// The create takes the plain path (the New Cloud Workspace dialog, or the bare create). One with an
    /// ``environment`` never does: that path would make the machine without it.
    public var takesPlainPath: Bool { isDefault && environment == nil }

    /// Where a named create in a Cloud environment (`cloud new-machine --name N --environment E`, which
    /// `cloud start-chat --environment` runs) stands against the machines this app knows.
    public enum NamedCreate: Equatable, Sendable {
        /// No machine and no create on its way has the name: make it.
        case free
        /// The machine list is not one the server answered just now for this account: it says nothing.
        case unread
        /// A machine has the name, or a create of it is on its way (or failed, waiting for Retry).
        case taken
    }

    /// ``NamedCreate`` for `name`: `listCurrent` is whether the list is current, `machines` its titles and
    /// `creating` the names of the creates on their way.
    public static func namedCreate(_ name: String, listCurrent: Bool, machines: [String], creating: [String]) -> NamedCreate {
        guard listCurrent else { return .unread }
        return machines.contains(name) || creating.contains(name) ? .taken : .free
    }

    /// ``NamedCreate`` of this request when it is named and boots in an ``environment`` (else ``free``): the
    /// list is read again (`refresh`) when it is not current, then judged with no wait between the judging and
    /// the caller's create, so a second ask for the name sees this one's create. `creating(name)` is the
    /// names of the creates on their way, with `name` when a `cloud start-session --name` is making it.
    public func namedCreate(listCurrent: () -> Bool, refresh: () async -> Void, machines: () -> [String],
                            creating: (String) -> [String]) async -> NamedCreate {
        guard environment != nil, let name else { return .free }
        if !listCurrent() { await refresh() }
        return Self.namedCreate(name, listCurrent: listCurrent(), machines: machines(), creating: creating(name))
    }

    /// A quoted `~/boot.sh` reaches the app unexpanded (`--bootstrap-script`, `--machine-config`).
    public static func expandingHome(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst()) : path
    }

    /// A file this request names (``bootstrapPath``, ``machineConfigPath``) could not be read, is
    /// empty or is over its size limit.
    public struct ScriptUnreadable: Error, Equatable {
        public var path: String
    }

    /// The bootstrap script from ``bootstrapPath``, read on `work`'s files lane, with ``repo``; a
    /// repo alone runs ``CloudMachineBootstrap/noScript``; nil with neither.
    public func loadScript(work: BackgroundWork) async throws -> CloudMachineBootstrap? {
        guard let path = bootstrapPath else { return repo.map { CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript, repo: $0) } }
        return CloudMachineBootstrap(kind: bootstrapKind, contents: try await Self.load(path, max: CloudMachineBootstrap.maxBytes, work: work), repo: repo)
    }

    /// The machine config from ``machineConfigPath``, read on `work`'s files lane; nil without one.
    public func loadMachineConfig(work: BackgroundWork) async throws -> CloudMachineConfig? {
        guard let path = machineConfigPath else { return nil }
        return CloudMachineConfig(contents: try await Self.load(path, max: CloudMachineConfig.maxBytes, work: work))
    }

    /// A regular file of at most `max` bytes, not empty; ``ScriptUnreadable`` otherwise. One open
    /// descriptor is checked (fstat: a regular file, never a FIFO or a device) and read with a hard
    /// limit, so a file swapped or grown after the check is never read past `max`.
    public static func load(_ path: String, max: Int, work: BackgroundWork) async throws -> Data {
        let data = try? await work.run(.userBlocking, mayBlock: .files) { () -> Data? in
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(max) else { return nil }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while data.count <= max {
                let read = buffer.withUnsafeMutableBytes { blockingRead(fd, $0.baseAddress, $0.count) }
                guard read > 0 else { return read == 0 ? data : nil }
                data.append(contentsOf: buffer[..<read])
            }
            return nil  // grew past `max` while it was read
        } ?? nil
        guard let data, !data.isEmpty, data.count <= max else { throw ScriptUnreadable(path: path) }
        return data
    }
}
