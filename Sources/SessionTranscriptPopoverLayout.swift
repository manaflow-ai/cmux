import CoreGraphics

struct SessionTranscriptPopoverLayout {
    let defaultSize = CGSize(width: 520, height: 500)
    let minSize = CGSize(width: 420, height: 320)
    let maxSize = CGSize(width: 920, height: 820)

    func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }
}
