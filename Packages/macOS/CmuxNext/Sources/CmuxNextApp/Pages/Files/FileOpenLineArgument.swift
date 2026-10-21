import Foundation
import CmuxNextActions
import CmuxNextSettings

/// Revalidates the optional line argument even for callers that bypass action schema validation.
struct FileOpenLineArgument {
    let location: FileLineLocation?

    init(_ value: JSONValue?) throws {
        guard let value, !value.isNull else { location = nil; return }
        guard let text = value.stringValue, let location = FileLineLocation(text) else {
            throw ActionFailure(message: String(localized: "file.open.invalidLine", defaultValue: "Line must be 1–10,000,000, optionally followed by :column or -endLine.", table: "FileOpenLine", bundle: .module))
        }
        self.location = location
    }
}
