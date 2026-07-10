import CmuxSimulator
import Foundation

struct SimulatorWebInspectorTargetCatalog {
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
            for (identifier, value) in dictionary {
                guard let raw = value as? [String: Any] else { continue }
                let application = simulatorWebInspectorApplication(
                    identifier: identifier,
                    value: raw
                )
                replacement[identifier] = application
            }
            let removed = Set(applications.keys).subtracting(replacement.keys)
            for identifier in removed { listings.removeValue(forKey: identifier) }
            applications = replacement
            return true
        case "_rpc_applicationConnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String else {
                return false
            }
            applications[identifier] = simulatorWebInspectorApplication(
                identifier: identifier,
                value: argument
            )
            return true
        case "_rpc_applicationDisconnected:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String else {
                return false
            }
            applications.removeValue(forKey: identifier)
            listings.removeValue(forKey: identifier)
            return true
        case "_rpc_applicationSentListing:":
            guard let identifier = argument["WIRApplicationIdentifierKey"] as? String,
                  let application = applications[identifier] else { return false }
            guard !application.isProxy else {
                listings.removeValue(forKey: identifier)
                return true
            }
            let rawListing = argument["WIRListingKey"] as? [String: Any] ?? [:]
            listings[identifier] = rawListing.values.compactMap { raw in
                guard let page = raw as? [String: Any],
                      let pageIdentifier = simulatorWebInspectorUnsignedInteger(
                          page["WIRPageIdentifierKey"]
                      )
                else { return nil }
                let connection = page["WIRConnectionIdentifierKey"] as? String
                return SimulatorWebInspectorTarget(
                    id: "\(identifier)|\(pageIdentifier)",
                    applicationIdentifier: identifier,
                    pageIdentifier: pageIdentifier,
                    title: page["WIRTitleKey"] as? String ?? "",
                    url: page["WIRURLKey"] as? String ?? "",
                    type: page["WIRTypeKey"] as? String ?? "",
                    applicationName: application.name,
                    bundleIdentifier: application.bundleIdentifier,
                    isInUse: connection?.isEmpty == false && connection != ownConnectionIdentifier
                )
            }
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
    let bundleIdentifier = value["WIRApplicationBundleIdentifierKey"] as? String
    return SimulatorWebInspectorApplication(
        identifier: identifier,
        bundleIdentifier: bundleIdentifier,
        name: value["WIRApplicationNameKey"] as? String
            ?? bundleIdentifier
            ?? identifier,
        isProxy: (value["WIRIsApplicationProxyKey"] as? NSNumber)?.boolValue
            ?? (value["WIRIsApplicationProxyKey"] as? Bool)
            ?? false
    )
}

private func simulatorWebInspectorUnsignedInteger(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? UInt64 { return value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? String { return UInt64(value) }
    return nil
}
