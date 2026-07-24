import Foundation

nonisolated struct TextBoxInlineAttachmentRenderKey: Hashable {
    let attachmentID: UUID
    let displayName: String
    let fontName: String
    let fontSize: CGFloat
    let fontTraits: UInt32
    let foregroundComponents: [CGFloat]
    let accentComponents: [CGFloat]
    let isFocused: Bool
    let appearanceName: String
    let backingScale: CGFloat
    let width: CGFloat
    let height: CGFloat
    let iconSize: CGFloat
    let thumbnailGeneration: UInt64
}
