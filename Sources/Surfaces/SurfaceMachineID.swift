import Foundation

/// Where a resource lives. `.local` is this Mac; `.cloud` is a cmux Cloud machine id;
/// `.device` is another Mac signed into the same account (one tagged app instance).
enum SurfaceMachineID: Hashable, Codable, Sendable, CustomStringConvertible {
    case local
    case cloud(String)
    case ssh(String)
    case device(SurfaceDeviceInstanceID)

    var description: String {
        switch self {
        case .local: return "local"
        case .cloud(let id): return id
        case .ssh(let id): return "ssh:" + id
        case .device(let instance): return instance.wireValue
        }
    }

    /// Wire form: `"local"`, the cloud machine id, or `device:<uuid>@<tag>`.
    var rawValue: String { description }
    var kind: String {
        switch self {
        case .local: return "local"
        case .cloud: return "cloud"
        case .ssh: return "ssh"
        case .device: return "device"
        }
    }

    /// `"local"` and the `device:` prefix are reserved; everything else is a cloud
    /// machine id, exactly as before devices existed.
    init(rawValue: String) {
        if rawValue == "local" {
            self = .local
        } else if rawValue.hasPrefix("ssh:") {
            self = .ssh(String(rawValue.dropFirst(4)))
        } else if let instance = SurfaceDeviceInstanceID(wireValue: rawValue) {
            self = .device(instance)
        } else {
            self = .cloud(rawValue)
        }
    }

    var isLocal: Bool { if case .local = self { return true } else { return false } }
    var cloudMachineID: String? { if case .cloud(let id) = self { return id } else { return nil } }
    var deviceInstance: SurfaceDeviceInstanceID? { if case .device(let instance) = self { return instance } else { return nil } }
    var isDevice: Bool { deviceInstance != nil }
    var isSSH: Bool { if case .ssh = self { return true }; return false }
    var tuiMachineID: String? {
        switch self {
        case .cloud(let id): return id
        case .ssh: return rawValue
        case .local, .device: return nil
        }
    }
}

