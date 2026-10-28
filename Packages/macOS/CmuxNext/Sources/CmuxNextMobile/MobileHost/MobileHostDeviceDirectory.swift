public import Foundation

/// The account's registered devices on the mobile service (`GET /v1/me/devices`,
/// `DELETE /v1/devices/:id`, cmux-next-ios/PROTOCOL.md 0.7.0), for Settings > Mobile's
/// phone list with Remove. A phone registers two device ids (its link and its
/// presence listener); ``MobileHostKnownPhone`` groups them under one name.
public struct MobileHostDeviceDirectory: Sendable {
    /// One request: the response body and status. Injected so tests need no network.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    public enum Failure: Error, Equatable, Sendable {
        case status(Int)
        case malformed
    }

    public let baseURL: URL
    private let send: Send

    public init(baseURL: URL, send: @escaping Send = MobileHostDeviceDirectory.urlSession) {
        self.baseURL = baseURL
        self.send = send
    }

    /// `URLSession.shared`; the status is 0 when the response is not HTTP.
    public static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The account's phones, grouped (link and presence ids under one name), newest first.
    public func phones(token: String) async throws -> [MobileHostKnownPhone] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        guard status == 200 else { throw Failure.status(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["devices"] as? [[String: Any]] else { throw Failure.malformed }
        return MobileHostKnownPhone.group(rows.compactMap(MobileHostRegisteredDevice.init(json:)))
    }

    /// Removes every id of `phone` on the service (404, already gone, counts as removed).
    public func remove(_ phone: MobileHostKnownPhone, token: String) async throws {
        for id in phone.deviceIDs {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/devices/\(id)"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, status) = try await send(request)
            guard status == 200 || status == 404 else { throw Failure.status(status) }
        }
    }
}

/// One `GET /v1/me/devices` row.
public struct MobileHostRegisteredDevice: Sendable, Equatable {
    public var deviceID: String
    public var kind: String
    public var name: String
    public var lastSeenAt: String?
    public var updatedAt: String?

    public init(deviceID: String, kind: String, name: String, lastSeenAt: String? = nil, updatedAt: String? = nil) {
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.lastSeenAt = lastSeenAt
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["deviceId"] as? String, let kind = json["kind"] as? String, let name = json["name"] as? String else { return nil }
        self.init(deviceID: id, kind: kind, name: name, lastSeenAt: json["lastSeenAt"] as? String, updatedAt: json["updatedAt"] as? String)
    }
}

/// A phone of the account: its name and every device id it registered.
public struct MobileHostKnownPhone: Sendable, Equatable, Identifiable {
    public var name: String
    public var deviceIDs: [String]
    /// The newest `updatedAt` of its ids (ISO 8601), for "last registered".
    public var updatedAt: String?
    /// Whether rows of the same name join this entry (its name is unique among the phones).
    var joinable = false

    public var id: String { deviceIDs.sorted().first ?? name }

    public init(name: String, deviceIDs: [String], updatedAt: String?) {
        self.name = name
        self.deviceIDs = deviceIDs
        self.updatedAt = updatedAt
    }

    /// The phone app names its presence id `<name> (presence)`; both ids are one phone.
    static let presenceSuffix = " (presence)"

    /// Phones only, in the order of their first (newest) row. A `<name> (presence)` row joins
    /// the one phone named `<name>`; when several phones share that name, nothing is joined and
    /// every row stays its own entry, so Remove never takes two phones at once.
    public static func group(_ devices: [MobileHostRegisteredDevice]) -> [MobileHostKnownPhone] {
        let phones = devices.filter { $0.kind == "phone" }
        let isPresence = { (device: MobileHostRegisteredDevice) in device.name.hasSuffix(presenceSuffix) }
        let base = { (device: MobileHostRegisteredDevice) in
            isPresence(device) ? String(device.name.dropLast(presenceSuffix.count)) : device.name
        }
        var linkCount: [String: Int] = [:]
        for device in phones where !isPresence(device) { linkCount[device.name, default: 0] += 1 }
        var result: [MobileHostKnownPhone] = []
        for device in phones {
            let name = base(device)
            let joinable = linkCount[name] == 1
            if joinable, let at = result.firstIndex(where: { $0.name == name && $0.joinable }) {
                result = result.enumerated().map { offset, phone in
                    guard offset == at else { return phone }
                    var merged = phone
                    merged.deviceIDs.append(device.deviceID)
                    if let updated = device.updatedAt, updated > (merged.updatedAt ?? "") { merged.updatedAt = updated }
                    return merged
                }
            } else {
                var phone = MobileHostKnownPhone(name: name, deviceIDs: [device.deviceID], updatedAt: device.updatedAt)
                phone.joinable = joinable
                result.append(phone)
            }
        }
        return result
    }

    /// Whether `phoneDeviceID` (a live link's phone id) is one of this phone's ids.
    public func owns(_ phoneDeviceID: String) -> Bool {
        deviceIDs.contains { $0.caseInsensitiveCompare(phoneDeviceID) == .orderedSame }
    }
}
