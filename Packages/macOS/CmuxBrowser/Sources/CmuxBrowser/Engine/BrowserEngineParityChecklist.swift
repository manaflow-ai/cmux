import Foundation

/// Where one engine stands on one capability.
public enum BrowserEngineParitySupport: Equatable, Sendable {
    /// The engine declares the capability and implements it.
    case supported
    /// The engine should support it and does not yet. `owner` is the area
    /// that closes the gap.
    case gap(owner: String)
    /// The engine cannot offer it (for example, WebKit has no Chrome DevTools
    /// Protocol). Callers branch on the capability instead.
    case notApplicable(reason: String)
}

/// One capability and where each engine stands on it.
public struct BrowserEngineParityEntry: Sendable {
    /// A stable name for messages, matching the capability's static name.
    public let name: String
    /// The capability, a single bit of ``BrowserEngineCapabilities``.
    public let capability: BrowserEngineCapabilities
    /// WebKit's support.
    public let webkit: BrowserEngineParitySupport
    /// Chromium's support.
    public let chromium: BrowserEngineParitySupport

    /// The support of `engine`.
    /// - Parameter engine: The engine.
    /// - Returns: That engine's column of this entry.
    public func support(for engine: BrowserEngineKind) -> BrowserEngineParitySupport {
        switch engine {
        case .webkit: webkit
        case .chromium: chromium
        }
    }
}

/// The checked-in parity checklist between the two browser engines.
///
/// Each engine's declared ``BrowserEngineCapabilities`` must equal the
/// checklist's `.supported` column for that engine
/// (``mismatches(declared:engine:)``). An engine that gains a capability, or
/// drops one, fails its package tests until this table says so, so the table
/// stays the parity matrix rather than a description of it.
public enum BrowserEngineParityChecklist {
    /// Every capability, once.
    public static let entries: [BrowserEngineParityEntry] = [
        entry("devTools", .devTools, webkit: .supported, chromium: .supported),
        entry("devToolsProtocol", .devToolsProtocol,
              webkit: .notApplicable(reason: "WebKit has no Chrome DevTools Protocol"),
              chromium: .supported),
        entry("extensions", .extensions,
              webkit: .notApplicable(reason: "WKWebView cannot load Chrome extensions"),
              chromium: .supported),
        entry("trustedInput", .trustedInput,
              webkit: .notApplicable(reason: "WebKit offers no trusted input injection"),
              chromium: .supported),
        entry("nativeFind", .nativeFind, webkit: .gap(owner: "devtools"), chromium: .supported),
        entry("findMatchCount", .findMatchCount, webkit: .supported, chromium: .supported),
        entry("snapshots", .snapshots, webkit: .supported, chromium: .supported),
        entry("downloads", .downloads, webkit: .supported, chromium: .supported),
        entry("paneFullscreen", .paneFullscreen, webkit: .supported, chromium: .supported),
        entry("crossOriginFrames", .crossOriginFrames,
              webkit: .notApplicable(reason: "WebKit content worlds cannot reach cross-origin frames"),
              chromium: .supported),
        entry("networkIntercept", .networkIntercept,
              webkit: .notApplicable(reason: "WKWebView cannot intercept http(s) requests"),
              chromium: .supported),
        entry("userScripts", .userScripts, webkit: .supported, chromium: .supported),
        entry("mediaMuting", .mediaMuting, webkit: .supported, chromium: .supported),
    ]

    /// Every capability the checklist names.
    public static var allCapabilities: BrowserEngineCapabilities {
        entries.reduce(into: []) { $0.formUnion($1.capability) }
    }

    /// The capabilities `engine` must declare.
    /// - Parameter engine: The engine.
    /// - Returns: The union of the entries marked `.supported` for it.
    public static func supported(by engine: BrowserEngineKind) -> BrowserEngineCapabilities {
        entries.reduce(into: []) { result, entry in
            if entry.support(for: engine) == .supported { result.formUnion(entry.capability) }
        }
    }

    /// The open gaps of `engine`, by capability name.
    /// - Parameter engine: The engine.
    /// - Returns: `name -> owner` for each `.gap` entry.
    public static func gaps(of engine: BrowserEngineKind) -> [String: String] {
        entries.reduce(into: [:]) { result, entry in
            if case let .gap(owner) = entry.support(for: engine) { result[entry.name] = owner }
        }
    }

    /// How an engine's declared capabilities differ from the checklist.
    /// - Parameters:
    ///   - declared: What the engine's pages report as ``BrowserPage/capabilities``.
    ///   - engine: The engine.
    /// - Returns: One message per difference; empty when they agree.
    public static func mismatches(
        declared: BrowserEngineCapabilities,
        engine: BrowserEngineKind
    ) -> [String] {
        var messages: [String] = []
        let unlisted = declared.subtracting(allCapabilities)
        if !unlisted.isEmpty {
            messages.append("\(engine.rawValue) declares capability bits 0x\(String(unlisted.rawValue, radix: 16)) the checklist does not list")
        }
        for entry in entries {
            let declares = declared.contains(entry.capability)
            let listed = entry.support(for: engine) == .supported
            if declares && !listed {
                messages.append("\(engine.rawValue) declares \(entry.name), which the checklist marks \(entry.support(for: engine))")
            } else if listed && !declares {
                messages.append("\(engine.rawValue) does not declare \(entry.name), which the checklist marks supported")
            }
        }
        return messages
    }

    private static func entry(
        _ name: String,
        _ capability: BrowserEngineCapabilities,
        webkit: BrowserEngineParitySupport,
        chromium: BrowserEngineParitySupport
    ) -> BrowserEngineParityEntry {
        BrowserEngineParityEntry(name: name, capability: capability, webkit: webkit, chromium: chromium)
    }
}
