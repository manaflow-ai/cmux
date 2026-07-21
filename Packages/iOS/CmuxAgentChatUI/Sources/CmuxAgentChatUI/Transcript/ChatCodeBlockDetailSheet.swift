import SwiftUI

/// Out-of-flow detail presentation for a fenced prose code block.
public struct ChatCodeBlockDetailSheet: View {
    private let id: String
    private let code: String
    private let language: String?

    public init(id: String, code: String, language: String?) {
        self.id = id
        self.code = code
        self.language = language
    }

    public var body: some View {
        ChatBlockDetailSheetView(
            detail: ChatBlockDetailBuilder().codeBlock(
                id: id,
                code: code,
                language: language
            )
        )
    }
}
