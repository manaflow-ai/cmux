public import CmuxTerminalSizing
internal import Foundation

#if canImport(UIKit)
internal import UIKit
#endif

/// How this phone describes itself to a shared terminal host:
/// `device_kind`, `device_name` and `device_id` in `mobile.terminal.viewport`.
public struct MobileTerminalDeviceIdentity: Equatable, Sendable {
    /// The longest device name sent, in characters.
    public static let maximumNameLength = 64

    /// `iphone` or `ipad`.
    public let kind: TerminalDeviceKind
    /// A short, single-line device name.
    public let name: String
    /// A stable per-install id (the vendor identifier), so two devices of one
    /// user get distinct priority keys. `nil` when the system has none yet.
    public let deviceID: String?

    /// Creates an identity, sanitizing `name` and falling back to `model`.
    /// - Parameters:
    ///   - kind: The device kind.
    ///   - name: The user-visible device name, possibly empty or generic.
    ///   - model: The generic model name ("iPhone", "iPad").
    ///   - deviceID: The stable per-install id, if known.
    public init(kind: TerminalDeviceKind, name: String?, model: String, deviceID: String? = nil) {
        self.kind = kind
        self.name = Self.sanitizedName(name) ?? Self.sanitizedName(model) ?? Self.fallbackName(for: kind)
        self.deviceID = deviceID.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// Collapses control characters and whitespace runs, trims, and caps the
    /// length. Returns `nil` for an empty result.
    /// - Parameter raw: The raw name.
    /// - Returns: The sanitized name, or `nil`.
    public static func sanitizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var result = ""
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        guard !result.isEmpty else { return nil }
        if result.count > maximumNameLength {
            result = String(result.prefix(maximumNameLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func fallbackName(for kind: TerminalDeviceKind) -> String {
        kind == .ipad ? "iPad" : "iPhone"
    }

    /// The identity of the running device.
    @MainActor
    public static func current() -> MobileTerminalDeviceIdentity {
        #if canImport(UIKit)
        let device = UIDevice.current
        let kind: TerminalDeviceKind = device.userInterfaceIdiom == .pad ? .ipad : .iphone
        return MobileTerminalDeviceIdentity(
            kind: kind,
            name: device.name,
            model: device.model,
            deviceID: device.identifierForVendor?.uuidString
        )
        #else
        return MobileTerminalDeviceIdentity(kind: .iphone, name: nil, model: "iPhone")
        #endif
    }
}
