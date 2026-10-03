public import CmuxNextSettings
import Foundation
import Observation

/// Interim backend: serves the page's `settings.*` operations from the
/// app's `SettingsController` (the validated writer) until the daemon
/// serves `settings-v1`; slice b of plans/cmux-next/settings-react.md
/// replaces it with a relay to the daemon and deletes this type. Shapes and
/// refusal codes are the daemon's, so the page does not change.
@MainActor
public final class ControllerSettingsBackend: SettingsPageBackend {
    private let settings: SettingsController
    private var observation: Task<Void, Never>?
    public var onChange: ((_ revision: Int, _ keys: [String]) -> Void)?

    public init(settings: SettingsController) {
        self.settings = settings
        observation = Task { [weak self, settings] in
            var last = settings.snapshot.root
            for await (count, root) in Observations({ (settings.loadCount, settings.snapshot.root) }) {
                guard let self else { return }
                let keys = SettingsSchema.all.filter { $0.storedValue(in: root) != $0.storedValue(in: last) }.map(\.id)
                last = root
                if !keys.isEmpty { self.onChange?(count, keys) }
            }
        }
    }

    isolated deinit {
        observation?.cancel()
    }

    public func request(_ operation: String, params: JSONValue) async throws -> JSONValue {
        switch operation {
        case "settings.list": return list(section: params["section"]?.stringValue)
        case "settings.snapshot": return snapshot()
        case "settings.set":
            let descriptor = try descriptor(params)
            guard let value = params["value"] else { throw SettingsPageError(code: "invalid_params", message: "settings.set requires value") }
            try await write(descriptor, value)
            return ["revision": .number(Double(settings.loadCount)), "keys": [.string(descriptor.id)]]
        case "settings.reset":
            let descriptor = try descriptor(params)
            try await write(descriptor, nil)
            return ["revision": .number(Double(settings.loadCount)), "keys": [.string(descriptor.id)]]
        case "settings.reset_all":
            try await settings.resetAllSettings()
            return ["revision": .number(Double(settings.loadCount))]
        default:
            throw SettingsPageError(code: "invalid_params", message: "unknown operation \(operation)")
        }
    }

    private func descriptor(_ params: JSONValue) throws -> SettingDescriptor {
        let key = params["key"]?.stringValue ?? ""
        guard let descriptor = SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)) else {
            throw SettingsPageError(code: "invalid_params", message: "\(key) is not a setting")
        }
        return descriptor
    }

    private func write(_ descriptor: SettingDescriptor, _ value: JSONValue?) async throws {
        do {
            try await settings.setSetting(descriptor, to: value)
        } catch let managed as SettingManaged {
            throw SettingsPageError(code: "managed", message: String(describing: managed), details: managedInfo(managed.source))
        } catch let refused as SettingRefused {
            throw SettingsPageError(code: "invalid_params", message: String(describing: refused))
        }
    }

    private func managedInfo(_ source: ManagedSource) -> JSONValue {
        let name: String = switch source {
        case .device: "device"
        case .team(let team): "team:\(team)"
        }
        let reason = switch source {
        case .device: SettingsWindowStrings.managedByOrganization
        case .team(let team): team.isEmpty ? SettingsWindowStrings.managedByOrganization : SettingsWindowStrings.managedByTeam(team)
        }
        return ["source": .string(name), "reason": .string(reason)]
    }

    private func list(section: String?) -> JSONValue {
        let root = settings.snapshot.root
        let file = settings.fileRoot
        let rows: [JSONValue] = SettingsSchema.all.filter { section == nil || $0.section.rawValue == section }.map { descriptor in
            [
                "key": .string(descriptor.id),
                "value": descriptor.effectiveValue(in: root) ?? .null,
                "default": descriptor.defaultValue ?? .null,
                "customized": .bool(descriptor.isCustomized(in: file)),
                "managed": settings.managedSource(for: descriptor).map(managedInfo) ?? .null,
            ]
        }
        return ["revision": .number(Double(settings.loadCount)), "rows": .array(rows)]
    }

    private func snapshot() -> JSONValue {
        var managed: [String: JSONValue] = [:]
        for (key, source) in settings.managedKeys { managed[key] = managedInfo(source) }
        let diagnostics: [JSONValue] = settings.diagnostics.map { ["path": .string($0.path), "message": .string($0.message)] }
        return [
            "revision": .number(Double(settings.loadCount)),
            "effective": settings.snapshot.root,
            "managed": .object(managed),
            "diagnostics": .array(diagnostics),
            "schema_hash": .string(""),
        ]
    }
}
