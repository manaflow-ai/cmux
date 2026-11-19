import Foundation

/// A dev build's own Cloud backend: the tag's hand-off (`cmux-next-ios/scripts/review.sh --backend`)
/// passes `CMUX_NEXT_CLOUD_BACKEND` at launch, the same name the Mac build reads, and the app keeps it
/// for its later launches (a tap on the icon carries no launch variables). An empty value (or
/// `default`) clears it: the build's own Cloud service again.
///
/// Allowed: the shared development deployment (`dev`, its API origin, a `preview-N` Worker) and a
/// tailnet origin (`https://<host>.<tailnet>.ts.net[:port]`, one tag's stack on the dev VM). Anything
/// else is refused and changes nothing. The Mac's Rust resolver (`cmux-cloud-environment`) holds
/// the same list.
///
/// Only DEBUG builds (Debug, Demo) call ``resolve(environment:defaults:)``: Release, TestFlight and
/// App Store builds compile the call out, and Production removes the stored value at launch
/// (``DeveloperOptions/storedKeys``).
public struct CloudBackendOverride: Sendable, Equatable {
    /// The backend's API origin.
    public var url: URL
    /// Where it came from.
    public var source: Source

    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }

    /// The launch variable, shared with the Mac build.
    public static let environmentKey = "CMUX_NEXT_CLOUD_BACKEND"
    /// `UserDefaults` key: the last accepted launch value.
    public static let storedKey = "cmuxMobile.dev.cloudBackend"
    /// The shared development deployment's Cloud API (Rust `DEVELOPMENT_API`).
    public static let developmentAPI = URL(string: "https://cmux-api-development.debussy.workers.dev")!

    /// Where the backend came from.
    public enum Source: String, Sendable, Equatable {
        /// This launch's `CMUX_NEXT_CLOUD_BACKEND`.
        case launch
        /// An earlier launch's, kept.
        case stored
        /// A rig's `CMUX_MOBILE_CLOUD_API_BASE` (``cloudService(environment:infoValue:defaults:debug:)``).
        case rig
        /// The build's Info.plist `CmuxMobileCloudAPIBase` (``cloudService(environment:infoValue:defaults:debug:)``).
        case build
    }

    /// The Cloud service this launch uses (Cloud Chief, Settings > Developer, the readiness receipt). With
    /// `debug` (DEBUG builds only), first this launch's `CMUX_NEXT_CLOUD_BACKEND`, then a rig's
    /// `CMUX_MOBILE_CLOUD_API_BASE`, then the kept override; always last, the build's Info.plist value.
    /// Release, TestFlight and App Store builds pass `debug: false` and read only Info.plist.
    public static func cloudService(environment: [String: String], infoValue: String?, defaults: UserDefaults,
                                    debug: Bool) -> CloudBackendOverride? {
        if debug {
            // Read (and kept, or cleared by an empty value) before the rig's variable, so a launch that
            // names both still records the hand-off's choice.
            let chosen = resolve(environment: environment, defaults: defaults)
            if let chosen, chosen.source == .launch { return chosen }
            if let raw = environment["CMUX_MOBILE_CLOUD_API_BASE"] {
                return URL(string: raw).flatMap { $0.host() == nil ? nil : CloudBackendOverride(url: $0, source: .rig) }
            }
            if let chosen { return chosen }
        }
        guard let infoValue, !infoValue.isEmpty, let url = URL(string: infoValue), url.host() != nil else { return nil }
        return CloudBackendOverride(url: url, source: .build)
    }

    /// How Settings > Developer and the receipt name it: `host[:port] (source)`.
    public var label: String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.host() ?? url.absoluteString)\(port) (\(source.rawValue))"
    }

    /// The allowed origin `value` names, or nil (refused).
    public static func allowed(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "dev", "development": return developmentAPI
        default: break
        }
        if let number = value.lowercased().split(separator: "-", maxSplits: 1).dropFirst().first,
           value.lowercased().hasPrefix("preview-") {
            return preview(String(number))
        }
        guard let components = URLComponents(string: value), let host = components.host?.lowercased(),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        if host == developmentAPI.host(), port.isEmpty { return developmentAPI }
        if let number = host.dropSuffix(".debussy.workers.dev")?.dropPrefix("cmux-api-preview-"), port.isEmpty {
            return preview(number)
        }
        guard let name = host.dropSuffix(".ts.net"), isTailnetMachine(name) else { return nil }
        return URL(string: "https://\(host)\(port)")
    }

    /// The backend for this launch: `CMUX_NEXT_CLOUD_BACKEND` when allowed (kept in `defaults` for later
    /// launches), else the kept one. An empty or `default` value clears the kept one and returns nil;
    /// a refused value changes nothing and returns the kept one.
    public static func resolve(environment: [String: String], defaults: UserDefaults) -> CloudBackendOverride? {
        if let raw = environment[environmentKey] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "default" {
                defaults.removeObject(forKey: storedKey)
                return nil
            }
            if let url = allowed(trimmed) {
                defaults.set(url.absoluteString, forKey: storedKey)
                return CloudBackendOverride(url: url, source: .launch)
            }
        }
        guard let stored = defaults.string(forKey: storedKey), let url = allowed(stored) else { return nil }
        return CloudBackendOverride(url: url, source: .stored)
    }

    private static func preview(_ number: String) -> URL? {
        guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), let value = UInt32(number), value > 0 else { return nil }
        return URL(string: "https://cmux-api-preview-\(value).debussy.workers.dev")
    }

    /// `host.tailnet`: at least two non-empty DNS labels of letters, digits and hyphens.
    private static func isTailnetMachine(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension String {
    func dropSuffix(_ suffix: String) -> String? { hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil }
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
