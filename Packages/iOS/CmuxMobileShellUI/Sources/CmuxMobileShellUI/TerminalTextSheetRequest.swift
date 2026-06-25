#if os(iOS)
import SwiftUI

struct TerminalTextSheetRequest: Identifiable {
    let surfaceID: String?
    let capture: Task<String?, Never>?
    var id: String { surfaceID ?? "__empty_terminal_text_request__" }
}
#endif
