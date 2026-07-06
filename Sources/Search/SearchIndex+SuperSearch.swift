import Foundation

extension SearchIndex: SearchIndexWriting {
    func deleteWorkspace(_ workspaceID: UUID) throws {
        try withStatement("DELETE FROM chunks WHERE workspace_id = ?1") { statement in
            try bind(workspaceID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    func deleteDocuments(idPrefix: String) throws {
        try withStatement("DELETE FROM chunks WHERE id LIKE ?1 ESCAPE '\\'") { statement in
            try bind(Self.escapedLikePrefix(idPrefix) + "%", at: 1, in: statement)
            try stepDone(statement)
        }
    }

    private static func escapedLikePrefix(_ prefix: String) -> String {
        var escaped = ""
        for character in prefix {
            switch character {
            case "\\":
                escaped.append("\\\\")
            case "%":
                escaped.append("\\%")
            case "_":
                escaped.append("\\_")
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
