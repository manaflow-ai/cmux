import Foundation

/// The inherited link may select a host and services, never an account, team or endpoint.
struct NativeCloudBrokerRequest: Decodable, Sendable {
    enum Operation: String, Decodable, Sendable {
        case connectInfo = "cloud.machine.connect_info"
        case linkToken = "cloud.machine.link_token"
    }
    enum Service: String, Codable, Sendable { case daemon, ssh }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, id, op, host, services }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    let id: UInt64
    let op: Operation
    let host: String
    let services: [Service]?

    init(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw NativeDeviceEnrollmentError.invalidScope }
        self = try JSONDecoder().decode(Self.self, from: bytes)
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw NativeDeviceEnrollmentError.invalidScope
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UInt64.self, forKey: .id)
        op = try values.decode(Operation.self, forKey: .op)
        host = try values.decode(String.self, forKey: .host)
        services = try values.decodeIfPresent([Service].self, forKey: .services)
        guard try values.decode(Int.self, forKey: .version) == 1, id > 0,
              host.hasPrefix("host_"), host.utf8.count == 25,
              host.dropFirst(5).allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else {
            throw NativeDeviceEnrollmentError.invalidScope
        }
        switch op {
        case .connectInfo:
            guard !values.contains(.services) else { throw NativeDeviceEnrollmentError.invalidScope }
        case .linkToken:
            guard let services, (1...2).contains(services.count), Set(services).count == services.count else {
                throw NativeDeviceEnrollmentError.invalidScope
            }
        }
    }
}
