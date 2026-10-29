import CMUXMobileCore
import Foundation

struct MobileSimulatorListResponse: Decodable, Sendable {
    let panels: [MobileSimulatorPanelDescriptor]

    static func decode(_ data: Data) throws -> MobileSimulatorListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

struct MobileSimulatorDevicesResponse: Decodable, Sendable {
    let devices: [MobileSimulatorDeviceDescriptor]

    static func decode(_ data: Data) throws -> MobileSimulatorDevicesResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct MobileSimulatorCommandResponse: Decodable, Sendable {
    public let ok: Bool?
    public let stopped: Bool?
    public let panelID: String?

    private enum CodingKeys: String, CodingKey {
        case ok, stopped
        case panelID = "panel_id"
    }

    static func decode(_ data: Data) throws -> MobileSimulatorCommandResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

struct MobileSimulatorRPCRequestEncoder: Sendable {
    func requestData<Parameters: Encodable>(method: String, parameters: Parameters) throws -> Data {
        let encoded = try JSONEncoder().encode(parameters)
        guard let params = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw MobileShellConnectionError.invalidResponse
        }
        return try MobileCoreRPCClient.requestData(method: method, params: params)
    }
}
