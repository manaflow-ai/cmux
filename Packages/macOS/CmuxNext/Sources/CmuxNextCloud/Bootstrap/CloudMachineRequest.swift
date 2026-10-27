import CmuxNextCompat
public import CmuxNextWakeups
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
    /// One key per request: the creation's Retry sends it again, so a create that reached the
    /// server but whose answer was lost does not make a second machine.
    public var idempotencyKey = UUID().uuidString
    /// The create was sent at least once with ``idempotencyKey``.
    public var wasSent = false
    /// The team the first send went to (`X-Cmux-Team-Id`): the key is scoped per team, so every
    /// retry, and the bootstrap and idle-pause calls on the machine, go to this team.
    public var team: String?
    /// The loaded bootstrap (``loadScript(work:)``), started by the create itself once the machine
    /// exists, so the creation's Retry starts it too.
    public var script: CloudMachineBootstrap?

    /// A machine name `cloud new-machine` takes: 1-64 of letters, digits, `.`, `_` and `-`, not
    /// starting with `-`, so it is also a host name and a shell word in the commands it prints.
    /// `true` is what a bare `--name` with no value becomes on its way to the app.
    public static func isPlainName(_ name: String) -> Bool {
        name != "true" && (1...64).contains(name.count) && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    public init(name: String? = nil, size: String? = nil, memoryMb: Int? = nil, persistent: Bool = false,
                bootstrapPath: String? = nil, bootstrapKind: CloudMachineBootstrap.Kind = .plain) {
        self.name = name
        self.size = size
        self.memoryMb = memoryMb
        self.persistent = persistent
        self.bootstrapPath = bootstrapPath
        self.bootstrapKind = bootstrapKind
    }

    public var isDefault: Bool { name == nil && size == nil && !persistent && bootstrapPath == nil }

    /// The script at ``bootstrapPath`` could not be read, is empty or is over ``CloudMachineBootstrap/maxBytes``.
    public struct ScriptUnreadable: Error, Equatable {
        public var path: String
    }

    /// The bootstrap script from ``bootstrapPath``, read on `work`'s files lane; nil without one.
    public func loadScript(work: BackgroundWork) async throws -> CloudMachineBootstrap? {
        guard let path = bootstrapPath else { return nil }
        let kind = bootstrapKind
        let data = try? await work.run(.userBlocking, mayBlock: .files) { () -> Data? in
            // A regular file of at most maxBytes: never a FIFO or a device, and nothing larger read.
            let attributes = try FileManager.checked.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= CloudMachineBootstrap.maxBytes else { return nil }
            return try Data(blockingContentsOf: URL(fileURLWithPath: path))
        } ?? nil
        guard let data, !data.isEmpty, data.count <= CloudMachineBootstrap.maxBytes else { throw ScriptUnreadable(path: path) }
        return CloudMachineBootstrap(kind: kind, contents: data)
    }
}
