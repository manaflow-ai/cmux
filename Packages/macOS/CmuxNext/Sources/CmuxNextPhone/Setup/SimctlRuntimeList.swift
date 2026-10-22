public import Foundation

/// Parses `xcrun simctl list runtimes -j` into the available iOS runtimes.
public struct SimctlRuntimeList: Sendable {
    public init() {}

    private struct Listing: Decodable {
        let runtimes: [Entry]
    }

    private struct Entry: Decodable {
        let identifier: String
        let name: String?
        let platform: String?
        let isAvailable: Bool?
        let supportedDeviceTypes: [TypeEntry]?
    }

    private struct TypeEntry: Decodable {
        let identifier: String
        let name: String
        let productFamily: String?
    }

    /// The available iOS runtimes in `json`, newest first.
    public func parse(_ json: Data) throws -> [SimctlRuntime] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        return listing.runtimes.compactMap { entry -> SimctlRuntime? in
            guard entry.isAvailable != false, let version = SimctlDeviceList.iosRuntime(entry.identifier) else { return nil }
            let phones = (entry.supportedDeviceTypes ?? [])
                .filter { $0.productFamily == "iPhone" || ($0.productFamily == nil && $0.name.hasPrefix("iPhone")) }
                .map { SimctlDeviceType(identifier: $0.identifier, name: $0.name) }
            return SimctlRuntime(identifier: entry.identifier, name: entry.name ?? "iOS " + version.map(String.init).joined(separator: "."),
                                 version: version, iPhoneTypes: phones)
        }
        .sorted { $1.version.lexicographicallyPrecedes($0.version) }
    }
}
