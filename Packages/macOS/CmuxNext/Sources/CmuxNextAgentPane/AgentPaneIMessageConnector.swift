import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextSettings
import Foundation

/// The shell forwards permission facts and person-originated actions to in-process Rust.
/// The database is never opened by acpmux, a helper, a peer, or the app's control socket.
@MainActor
public protocol AgentPaneIMessageHost: AnyObject {
    var imessageSettings: SettingsController? { get }
    func imessageHasFullDiskAccess() async -> Bool
    func imessageHasAutomation() async -> Bool
    func imessageAskAutomation() async
    func imessageOpenFullDiskAccess()
    func imessagePermissionChanges() -> AsyncStream<Void>
}

@MainActor
public final class AgentPaneIMessageConnector {
    private weak var host: (any AgentPaneIMessageHost)?
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var changes: Task<Void, Never>?
    private var configChanges: Task<Void, Never>?

    public init(host: any AgentPaneIMessageHost) { self.host = host }

    nonisolated deinit { changes?.cancel(); configChanges?.cancel() }

    public func respond(_ action: AgentPaneIMessageAction, view: AgentPaneView) async -> [String: Any] {
        views.add(view)
        follow()
        guard let host, let settings = host.imessageSettings else { return unavailable() }
        switch action {
        case .fullDiskAccess:
            host.imessageOpenFullDiskAccess()
        case .automation:
            // Same existing Automation path as SystemPermissionOpener; await the person's answer
            // so the returned status reflects it, even when macOS does not change app activation.
            await host.imessageAskAutomation()
        default: break
        }
        let disk = await host.imessageHasFullDiskAccess()
        let automation = await host.imessageHasAutomation()
        let home = FileManager.default.homeDirectoryForCurrentUser
        func request(_ operation: String) -> JSONValue { [
            "action": .string(operation),
            "enabled": .bool(settings.snapshot.imessageEnabled),
            "automation_skipped": .bool(settings.snapshot.imessageAutomationSkipped),
            "database_path": .string(home.appending(path: "Library/Messages/chat.db").path),
            "full_disk_access": .bool(disk),
            "automation": .bool(automation),
        ] }
        guard var value = await Self.call(request(action == .fullDiskAccess || action == .automation ? "status" : action.rawValue)) else {
            return unavailable()
        }
        if let writes = value["setting_writes"]?.arrayValue, !writes.isEmpty {
            do {
                for write in writes {
                    guard let key = write["key"]?.stringValue, let enabled = write["value"]?.boolValue else { return unavailable() }
                    try await settings.setSetting(at: key.split(separator: ".").map(String.init), to: .bool(enabled), by: .user)
                }
            } catch {
                invalidate()
                return AgentPaneReply.failure(code: "connection_state", message: "connection_state")
            }
            // The settings owner has committed and reloaded. Return its effective values, including policy.
            guard let committed = await Self.call(request("status")) else { return unavailable() }
            value = committed
        }
        if !action.isPassive { invalidate() }
        return AgentPaneReply.success(value.foundationObject)
    }

    /// The existing app Rust JSON channel; SQLite reads stay off-main.
    @concurrent nonisolated private static func call(_ request: JSONValue) async -> JSONValue? {
        CloudStartCore().call("imessage", IMessageWire(request), as: IMessageWire.self)?.value
    }

    private func invalidate() { for view in views.allObjects { view.iMessageChanged() } }
    private func unavailable() -> [String: Any] { AgentPaneReply.failure(code: "unavailable", message: "unavailable") }

    private func follow() {
        guard changes == nil, let host else { return }
        let stream = host.imessagePermissionChanges()
        // task-owner: connector lifetime; deinit cancels and the probe removes its observers.
        // Events only: app activation after System Settings and grant changes, never polling.
        changes = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                invalidate()
            }
        }
        let settings: @MainActor () -> SettingsController? = { [weak host] in host?.imessageSettings }
        // task-owner: connector lifetime; deinit cancels. Kernel-backed settings changes only.
        configChanges = Task { [weak self] in
            for await _ in ObservationStream({ (settings()?.snapshot.imessageEnabled, settings()?.snapshot.imessageAutomationSkipped) }) {
                self?.invalidate()
            }
        }
    }
}

/// Settings' JSONValue carries no Codable conformance; the FFI channel speaks Codable.
private nonisolated struct IMessageWire: Codable, Sendable {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = .null }
        else if let bool = try? container.decode(Bool.self) { value = .bool(bool) }
        else if let number = try? container.decode(Double.self) { value = .number(number) }
        else if let string = try? container.decode(String.self) { value = .string(string) }
        else if let array = try? container.decode([IMessageWire].self) { value = .array(array.map(\.value)) }
        else { value = .object(try container.decode([String: IMessageWire].self).mapValues(\.value)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array.map(IMessageWire.init))
        case .object(let object): try container.encode(object.mapValues(IMessageWire.init))
        }
    }
}
