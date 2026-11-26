public import Foundation

/// The name this Mac registers with the mobile service: what the iPhone app lists it by.
///
/// Every cmux build on a Mac is its own device (its own id, identity key and paired phones), and the
/// phone lists each one. The Stable lane goes by the computer's name alone; any other build adds its
/// lane (`BuildIdentity.instanceLabel`) so a person tells them apart: `Aziz's MacBook Pro` and
/// `Aziz's MacBook Pro (NIGHTLY)`. The phone app names itself the same way (cmux-next-ios
/// `DeviceInstanceName`).
public struct MobileHostDeviceName: Sendable, Equatable {
    /// The computer's name (System Settings > General > Sharing).
    public let computer: String
    /// The build's lane; nil for the Stable lane.
    public let label: String?

    public init(computer: String, label: String?) {
        self.computer = computer
        self.label = label
    }

    /// The computer's name, then the lane in parentheses when there is one.
    public var value: String {
        let name = computer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return name }
        return name.isEmpty ? label : "\(name) (\(label))"
    }
}
