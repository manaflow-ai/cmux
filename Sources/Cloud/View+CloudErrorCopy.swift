import SwiftUI

extension View {
    func cloudErrorCopyMenu(_ text: String?) -> some View {
        contextMenu {
            if let text, !text.isEmpty {
                Button(CloudErrorCopy.title) { CloudErrorCopy.copy(text) }
            }
        }
    }
}
