public import AppKit

/// A drag's pasteboard as drop contents: file URLs only, and a picture any `NSImage` type reads.
extension NSPasteboard: FileGridDropContents {
    public var droppedFileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    public var droppedImage: NSImage? { NSImage(pasteboard: self) }

    public var holdsImage: Bool { NSImage.canInit(with: self) }
}
