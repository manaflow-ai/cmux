import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore {
    struct MacRow {
        let macDeviceID: String
        let ownerKey: String
        let displayName: String?
        let stackUserID: String?
        let teamID: String?
        let createdAt: Date
        let lastSeenAt: Date
        let isActive: Bool
        var customName: String? = nil
        var customColor: String? = nil
        var customIcon: String? = nil
        var irohEndpointID: String? = nil
    }

    enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    static func encodeRoute(_ route: CmxAttachRoute) throws -> String {
        let data = try JSONEncoder().encode(route)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        return string
    }

    static func readNullableText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}
