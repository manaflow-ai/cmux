import AppKit
import CmuxNextDesign
import ImageIO

/// A Chief's existing picture or text face. File decoding stays off the main actor and runs only
/// when the face changes; a recycled row cancels its load and cannot receive the previous face.
final class SidebarChiefAvatarView: NSView {
    var avatar: SidebarChiefAvatar? { didSet { if avatar != oldValue { load() } } }
    private var picture: SidebarFavicon?
    private var loading: Task<Void, Never>?
    nonisolated deinit { loading?.cancel() }
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func load() {
        loading?.cancel()
        picture = nil
        needsDisplay = true
        guard case .picture(let url) = avatar else { return }
        // One bounded image decode, no timer. Cancellation discards the result on reuse.
        loading = Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> SidebarFavicon? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 64,
                      ] as CFDictionary) else { return nil }
                return SidebarFavicon(image)
            }.value
            guard !Task.isCancelled, let self, self.avatar == .picture(url) else { return }
            self.picture = image
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            if let picture {
                NSImage(cgImage: picture.image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver,
                                                                      fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let text: String
                if case .text(let own) = avatar { text = own } else { text = "" }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: bounds.height * (text.allSatisfy { $0.isLetter || $0.isNumber } ? 0.52 : 0.85)),
                    .foregroundColor: Palette.textPrimary,
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}
