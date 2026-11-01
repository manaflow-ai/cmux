import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The markdown page's table column widths (plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md): the
/// config carries the saved value as `tableWidths`, and `cmux.markdown.setTableWidths {path,
/// value}` saves it (value null forgets it). The page sends one call per finished resize, never
/// per drag frame; the host stores the page's JSON as is through ``MarkdownTableWidthStoring``.
extension FilePageProvider {
    /// The saved widths of `url` as the page's JSON object, or nil.
    func savedTableWidths(_ url: URL) async -> JSONValue? {
        guard let tableWidths, let data = await tableWidths.read(url.path),
              let value = try? JSONValue.parse(data), Self.isTableWidths(value) else { return nil }
        return value
    }

    /// `cmux.markdown.setTableWidths {path, value}`: answers where the value landed.
    func setTableWidths(_ params: JSONValue) async throws -> JSONValue {
        let url = try path(params["path"])
        guard let file, canonical(url) == file else { throw PageError.invalidParams("path is not this page's file") }
        let data: Data?
        switch params["value"] {
        case .null?, nil:
            data = nil
        case let value? where Self.isTableWidths(value):
            let bytes = Data(value.compactText.utf8)
            guard bytes.count <= MarkdownTableWidthRepository.valueLimit else { throw PageError.invalidParams("value is too large") }
            data = bytes
        default:
            throw PageError.invalidParams("value must be {v, tables} or null")
        }
        guard let tableWidths else { return ["attribute": false, "fallback": false] }
        let written = await tableWidths.write(file.path, data)
        return ["attribute": .bool(written.attribute), "fallback": .bool(written.fallback)]
    }

    /// The page's shape: `{v: 1, tables: [{i, h, w: [numbers]}]}`.
    nonisolated static func isTableWidths(_ value: JSONValue) -> Bool {
        guard value["v"]?.intValue == 1, let tables = value["tables"]?.arrayValue, tables.count <= 256 else { return false }
        return tables.allSatisfy { table in
            guard table["i"]?.intValue != nil, table["h"]?.stringValue != nil, let widths = table["w"]?.arrayValue else { return false }
            return widths.count <= 256 && widths.allSatisfy { ($0.doubleValue ?? 0) > 0 }
        }
    }
}
