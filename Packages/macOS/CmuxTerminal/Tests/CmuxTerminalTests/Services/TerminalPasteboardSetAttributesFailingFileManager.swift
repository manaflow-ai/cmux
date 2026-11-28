import Foundation

/// A file manager that rejects permission changes after allowing file moves.
final class TerminalPasteboardSetAttributesFailingFileManager:
    FileManager,
    @unchecked Sendable
{
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
