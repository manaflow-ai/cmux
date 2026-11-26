public import Foundation

/// The cloud build space every call of a hub client carries (`X-Cmux-Build-Space`, docs/device-hub/PROTOCOL.md
/// "Build spaces"). The App decides it once from its build identity (the build's `CMUXBuildSpaceState`) and passes it
/// in; this module never reads a bundle. Each space is its own set of devices on the hub, so a tagged dev build's Mac
/// and iPhone see only each other, never another tag's, NIGHTLY's or a release build's devices of the same account.
public enum DeviceHubBuildSpace: Sendable, Equatable {
    /// NIGHTLY, RC, release, TestFlight and App Store builds: no header, the hub's default space.
    case nightly
    /// A tagged dev build: its header value, `dev:<slug>`, on every request and socket upgrade.
    case dev(String)
    /// A dev build with no usable tag: every hub call is refused before it is sent (``DeviceHubError/notConfigured``),
    /// so it never lands among NIGHTLY's devices.
    case unusable

    /// The header every cloud backend reads.
    public static let headerName = "X-Cmux-Build-Space"

    /// `dev:<slug>` for a dev build; nil for the default space and an unusable one.
    public var headerValue: String? {
        if case let .dev(value) = self { value } else { nil }
    }

    /// Adds the header to `request`; throws for an unusable space, so the request is never sent.
    func apply(to request: inout URLRequest) throws {
        switch self {
        case .nightly: return
        case let .dev(value): request.setValue(value, forHTTPHeaderField: Self.headerName)
        case .unusable: throw DeviceHubError.notConfigured
        }
    }

    /// Adds the header to a socket upgrade's headers; throws for an unusable space.
    func apply(to headers: inout [String: String]) throws {
        switch self {
        case .nightly: return
        case let .dev(value): headers[Self.headerName] = value
        case .unusable: throw DeviceHubError.notConfigured
        }
    }
}
