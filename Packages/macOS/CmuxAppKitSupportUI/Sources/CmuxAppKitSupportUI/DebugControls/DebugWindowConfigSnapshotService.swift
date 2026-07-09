#if canImport(AppKit)
#if DEBUG

public import AppKit
public import Foundation

/// Copies a combined snapshot of the app's debug configuration onto the general
/// pasteboard for the "Debug Window Controls" panel's "Copy All Debug Config"
/// action.
///
/// This service owns the two reusable halves of that action: the
/// `UserDefaults`-coercion helpers (``stringValue(key:fallback:)``,
/// ``doubleValue(key:fallback:)``, ``boolValue(key:fallback:)``) that read a
/// value with a fallback in the exact shape the legacy snapshot used, and the
/// pasteboard plumbing (``copyCombinedToPasteboard()``). The combined payload
/// text is irreducibly app-coupled (it interpolates app-target settings enums and
/// catalog-section keys), so the app target supplies it through the injected
/// ``payload`` closure. Keeping the payload closure in the app keeps this package
/// free of app-settings imports while still draining the coercion helpers and the
/// pasteboard mechanism out of the god file.
///
/// The closure is `@MainActor`-isolated and the type is `@MainActor` because the
/// sole caller (the panel button) runs on the main actor and the pasteboard write
/// is a main-thread AppKit operation; this mirrors the legacy call site, which ran
/// synchronously inside the SwiftUI button action.
@MainActor
public final class DebugWindowConfigSnapshotService {
    /// The defaults read by the coercion helpers. Injected so tests can pass a
    /// scoped `UserDefaults(suiteName:)`.
    public let defaults: UserDefaults

    /// Builds the combined payload text. Supplied by the app target because the
    /// payload interpolates app-coupled settings types; this service never names
    /// those types itself.
    private let payload: @MainActor (DebugWindowConfigSnapshotService) -> String

    /// The pasteboard the snapshot is written to. Injected (defaulting to
    /// `.general`) so tests can observe the written string without touching the
    /// shared pasteboard.
    private let pasteboard: NSPasteboard

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - defaults: The defaults the coercion helpers read.
    ///   - pasteboard: The pasteboard the combined payload is written to. Defaults
    ///     to `NSPasteboard.general`.
    ///   - payload: Builds the combined payload text. Invoked on the main actor
    ///     each time ``copyCombinedToPasteboard()`` runs. The service is passed in
    ///     so the app can build this string from app-target settings using the
    ///     coercion helpers without self-referential capture.
    public init(
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        payload: @escaping @MainActor (DebugWindowConfigSnapshotService) -> String
    ) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.payload = payload
    }

    /// Writes the combined payload onto the pasteboard, replacing its contents.
    public func copyCombinedToPasteboard() {
        pasteboard.clearContents()
        pasteboard.setString(payload(self), forType: .string)
    }

    /// Reads `key` as a string, returning `fallback` when it is absent.
    public func stringValue(key: String, fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    /// Reads `key` as a double, accepting either a numeric default or a numeric
    /// string, and returning `fallback` when neither is present or parseable.
    public func doubleValue(key: String, fallback: Double) -> Double {
        if let value = defaults.object(forKey: key) as? NSNumber {
            return value.doubleValue
        }
        if let text = defaults.string(forKey: key), let parsed = Double(text) {
            return parsed
        }
        return fallback
    }

    /// Reads `key` as a bool, returning `fallback` when the key is absent.
    public func boolValue(key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

#endif
#endif
