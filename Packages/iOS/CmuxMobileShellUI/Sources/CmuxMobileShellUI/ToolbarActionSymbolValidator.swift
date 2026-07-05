#if os(iOS)
import Foundation
import UIKit

/// Validates optional SF Symbol names for custom toolbar actions.
struct ToolbarActionSymbolValidator {
    private let imageProvider: (String) -> UIImage?

    init(imageProvider: @escaping (String) -> UIImage? = { UIImage(systemName: $0) }) {
        self.imageProvider = imageProvider
    }

    /// Returns a trimmed SF Symbol name only when UIKit can render it.
    func validatedSymbolName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, imageProvider(trimmed) != nil else {
            return nil
        }
        return trimmed
    }
}
#endif
