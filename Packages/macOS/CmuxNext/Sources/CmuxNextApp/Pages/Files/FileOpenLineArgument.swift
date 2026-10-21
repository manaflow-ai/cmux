import Foundation
import CmuxNextActions
import CmuxNextSettings

/// Revalidates the optional line argument even for callers that bypass action schema validation.
struct FileOpenLineArgument {
    let location: FileLineLocation?

    init(_ value: ActionValue?) throws {
        guard let value else { location = nil; return }
        let text: String? = switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .bool, .target: nil
        }
        guard let text, let location = FileLineLocation(text) else {
            throw ActionFailure(message: String(localized: "file.open.invalidLine", defaultValue: "Line must be a number from 1 to 10,000,000, optionally followed by :column or -endLine.", table: "FileOpenLine", bundle: .module))
        }
        self.location = location
    }
}
