import Foundation
import SQLite3

extension InboxSQLiteStore {
    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InboxError.invalidParameters("Failed to encode inbox JSON")
        }
        return string
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw InboxError.invalidParameters("Failed to decode inbox JSON")
        }
        return try decoder.decode(type, from: data)
    }

    func sqliteDate(_ date: Date?) -> InboxDatabase.BindValue {
        guard let date else { return .null }
        return .real(date.timeIntervalSince1970)
    }

    func dateFromColumn(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func stringFromColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    func optionalStringFromColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return stringFromColumn(statement, index)
    }
}
