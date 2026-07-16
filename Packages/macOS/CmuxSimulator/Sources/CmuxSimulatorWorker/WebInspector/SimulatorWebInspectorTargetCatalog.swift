import CmuxSimulator
import Foundation

struct SimulatorWebInspectorTargetCatalog {
    static let maximumApplicationCount = 512
    static let maximumTargetCount = 512
    static let maximumFieldBytes = 4 * 1_024
    static let maximumRetainedTargetStringBytes = 512 * 1_024

    private var applications: [String: SimulatorWebInspectorApplication] = [:]
    private var listings: [String: [SimulatorWebInspectorTarget]] = [:]

    var targets: [SimulatorWebInspectorTarget] {
        listings.values
            .flatMap { $0 }
            .sorted {
                if $0.applicationName != $1.applicationName {
                    return $0.applicationName.localizedStandardCompare($1.applicationName)
                        == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var inspectableApplicationIdentifiers: [String] {
        applications.values
            .filter { !$0.isProxy }
            .map(\.identifier)
            .sorted()
    }

    mutating func reset() {
        applications.removeAll()
        listings.removeAll()
    }

    @discardableResult
    mutating func apply(
        _ message: [String: Any],
        ownConnectionIdentifier: String
    ) -> Bool {
        guard let selector = message["__selector"] as? String,
              let argument = message["__argument"] as? [String: Any] else { return false }
        switch selector {
        case "_rpc_reportConnectedApplicationList:":
            let dictionary = argument["WIRApplicationDictionaryKey"] as? [String: Any] ?? [:]
            var replacement: [String: SimulatorWebInspectorApplication] = [:]
            for (identifier, value) in dictionary.prefix(Self.maximumApplicationCount) {
                guard identifier.utf8.count <= Self.maximumFieldBytes else { continue }
                guard let raw = value as? [String: Any] else { continue }
                let application = simulatorWebInspectorApplication(
                    identifier: identifier,
                    value: raw
                )
                replacement[identifier] = application
            }
            let removed = Set(applications.keys).subtracting(replacement.keys)
            for identifier in removed { listings.removeValue(forKey: identifier) }
            guard applications != replacement || !removed.isEmpty else { return false }
            applications = replacement
            return true
        case "_rpc_applicationConnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String,
                  identifier.utf8.count <= Self.maximumFieldBytes else {
                return false
            }
            guard applications[identifier] != nil
                    || applications.count < Self.maximumApplicationCount else { return false }
            let application = simulatorWebInspectorApplication(
                identifier: identifier,
                value: argument
            )
            guard applications[identifier] != application else { return false }
            applications[identifier] = application
            return true
        case "_rpc_applicationDisconnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String else {
                return false
            }
            let removedApplication = applications.removeValue(forKey: identifier) != nil
            let removedListing = listings.removeValue(forKey: identifier) != nil
            return removedApplication || removedListing
        case "_rpc_applicationSentListing:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String,
                  identifier.utf8.count <= Self.maximumFieldBytes,
                  let application = applications[identifier] else { return false }
            guard !application.isProxy else {
                return listings.removeValue(forKey: identifier) != nil
            }
            let rawListing = argument["WIRListingKey"] as? [String: Any] ?? [:]
            let retainedTargets = listings.lazy
                .filter { $0.key != identifier }
                .flatMap(\.value)
            var remainingCount = Self.maximumTargetCount - retainedTargets.count
            var remainingBytes = Self.maximumRetainedTargetStringBytes
                - retainedTargets.reduce(into: 0) { $0 += retainedStringBytes(of: $1) }
            var replacement: [SimulatorWebInspectorTarget] = []
            for raw in rawListing.values where remainingCount > 0 {
                guard let page = raw as? [String: Any],
                      let pageIdentifier = simulatorWebInspectorUnsignedInteger(
                          page["WIRPageIdentifierKey"]
                      )
                else { continue }
                let connection = page["WIRConnectionIdentifierKey"] as? String
                let target = SimulatorWebInspectorTarget(
                    id: "\(identifier)|\(pageIdentifier)",
                    applicationIdentifier: identifier,
                    pageIdentifier: pageIdentifier,
                    title: boundedWebInspectorString(page["WIRTitleKey"] as? String),
                    url: boundedWebInspectorString(page["WIRURLKey"] as? String),
                    type: boundedWebInspectorString(page["WIRTypeKey"] as? String),
                    applicationName: application.name,
                    bundleIdentifier: application.bundleIdentifier,
                    isInUse: connection?.isEmpty == false && connection != ownConnectionIdentifier
                )
                let charge = retainedStringBytes(of: target)
                guard charge <= remainingBytes else { continue }
                replacement.append(target)
                remainingCount -= 1
                remainingBytes -= charge
            }
            replacement.sort { $0.pageIdentifier < $1.pageIdentifier }
            guard listings[identifier] != replacement else { return false }
            listings[identifier] = replacement
            return true
        default:
            return false
        }
    }

    func target(id: String) -> SimulatorWebInspectorTarget? {
        targets.first(where: { $0.id == id })
    }

}

private func simulatorWebInspectorApplication(
    identifier: String,
    value: [String: Any]
) -> SimulatorWebInspectorApplication {
    let bundleIdentifier = boundedWebInspectorOptionalString(
        value["WIRApplicationBundleIdentifierKey"] as? String
    )
    return SimulatorWebInspectorApplication(
        identifier: identifier,
        bundleIdentifier: bundleIdentifier,
        name: boundedWebInspectorOptionalString(value["WIRApplicationNameKey"] as? String)
            ?? bundleIdentifier
            ?? boundedWebInspectorString(identifier),
        isProxy: (value["WIRIsApplicationProxyKey"] as? NSNumber)?.boolValue
            ?? (value["WIRIsApplicationProxyKey"] as? Bool)
            ?? false
    )
}

private func boundedWebInspectorOptionalString(_ value: String?) -> String? {
    guard let value else { return nil }
    return boundedWebInspectorString(value)
}

private func boundedWebInspectorString(_ value: String?) -> String {
    guard let value else { return "" }
    return String(decoding: value.utf8.prefix(
        SimulatorWebInspectorTargetCatalog.maximumFieldBytes
    ), as: UTF8.self)
}

private func retainedStringBytes(of target: SimulatorWebInspectorTarget) -> Int {
    target.id.utf8.count
        + target.applicationIdentifier.utf8.count
        + target.title.utf8.count
        + target.url.utf8.count
        + target.type.utf8.count
        + target.applicationName.utf8.count
        + (target.bundleIdentifier?.utf8.count ?? 0)
}

private func simulatorWebInspectorUnsignedInteger(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? UInt64 { return value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? String { return UInt64(value) }
    return nil
}
